-- vmhunter_amd.lua -- FreeSWITCH client for the vmhunter AMD WebSocket server
-- Works with mod_audio_fork (drachtio) or mod_audio_stream (amigniter); auto-detects which one is loaded.
--
-- Run on the CUSTOMER leg right after answer (see vmhunter_amd.xml).
-- Streams ~2 s of far-end audio to vmhunter and sets these channel variables:
--   AMDSTATUS      HUMAN | MACHINE                          (route on this one)
--   AMDSTATUS_RAW  HUMAN | MACHINE | CALLGUARD | FAILED     (untouched server verdict)
--   AMDCAUSE       HUMAN | MACHINE | MACHINE_BEEP | DISCONNECT | MACHINE_STATIC |
--                  INITIALSILENCE | MAXWORD | CALLGUARD_PHRASE:<...> | AUTH_FAILED |
--                  SPEECHLLM_ENGINE_UNAVAILABLE | ...
--   Call screening always shows in AMDCAUSE as CALLGUARD_PHRASE:<...>, whatever
--   AMDSTATUS the server is configured to send; vmhunter_amd.xml branches on it.
--
-- Channel variables read (set them in the originate string or in vars.xml):
--   vid               lead / call id sent to vmhunter (billing + recording name). Falls back to the uuid.
--   vmhunter_ws_url   server URL           (default ws://app.vmhunter.com:2701)
--   vmhunter_api_key  your vmhunter API key (required)
--   vmhunter_module   audio_fork | audio_stream  (optional; auto-detected when unset)
--
-- Protocol (same as vmhunter.agi.py for Asterisk):
--   text  {"config":{"vid":..,"api_key":..,"sample_rate":8000,"bytes_per_sample":2}}   <- module metadata argument
--   binary raw s16le mono 8 kHz PCM                                                    <- module "mono 8k"
--   text  {"AMDSTATUS":"..","AMDCAUSE":".."} from the server, then the server closes  <- mod_<module>::json event

local DEFAULT_WS_URL = "ws://app.vmhunter.com:2701"
local WAIT_MS        = 6000      -- server budget: 2 s audio + up to 3 s SpeechLLM analysis
local POLL_MS        = 100
local CALLGUARD_AS   = "HUMAN"   -- HUMAN (default, connect to agent) | MACHINE (drop)
local FAILED_AS      = "MACHINE" -- fail-safe when the server errors or never replies

local function var(name, default)
  local v = session:getVariable(name)
  if v == nil or v == "" then v = freeswitch.getGlobalVariable(name) end
  if v == nil or v == "" then return default end
  return v
end

local uuid    = session:get_uuid()
local ws_url  = var("vmhunter_ws_url", DEFAULT_WS_URL)
local api_key = var("vmhunter_api_key", "")
local vid     = var("vid", uuid)
local api     = freeswitch.API()

-- Pick the streaming module: explicit vmhunter_module, else whichever is loaded (fork first).
local module = var("vmhunter_module", "")
if module == "" then
  if api:executeString("module_exists mod_audio_fork"):find("true") then
    module = "audio_fork"
  elseif api:executeString("module_exists mod_audio_stream"):find("true") then
    module = "audio_stream"
  else
    module = "audio_fork"
  end
end
local CMD = "uuid_" .. module          -- uuid_audio_fork | uuid_audio_stream
local EV  = "mod_" .. module .. "::"   -- mod_audio_fork:: | mod_audio_stream::

-- Fail-safe defaults in case anything below bails out early.
session:setVariable("AMDSTATUS", FAILED_AS)
session:setVariable("AMDSTATUS_RAW", "FAILED")
session:setVariable("AMDCAUSE", "NOT_RUN")

if api_key == "" then
  freeswitch.consoleLog("ERR", "[vmhunter] vmhunter_api_key not set uuid=" .. uuid .. "\n")
  return
end

-- Subscribe BEFORE starting the fork so the reply can never be missed.
local con = freeswitch.EventConsumer("CUSTOM", EV .. "json")
con:bind("CUSTOM", EV .. "connect_failed")
con:bind("CUSTOM", EV .. "disconnect")
con:bind("CUSTOM", EV .. "error")

-- Both modules send the metadata argument as the first text frame after connecting,
-- which is exactly vmhunter's config message. It is one fs_api argument: NO spaces.
local meta = string.format(
  '{"config":{"vid":"%s","api_key":"%s","sample_rate":8000,"bytes_per_sample":2}}',
  vid, api_key)

local res = api:executeString(string.format(
  "%s %s start %s mono 8k %s", CMD, uuid, ws_url, meta))
if res:find("^%-ERR") then
  freeswitch.consoleLog("ERR", "[vmhunter] " .. CMD .. " start failed uuid=" .. uuid .. " res=" .. res .. "\n")
  session:setVariable("AMDCAUSE", "STREAM_START_FAILED")
  return
end

local raw, cause = "FAILED", "NO_REPLY"
local waited = 0
while waited < WAIT_MS and session:ready() do
  local e = con:pop(1, POLL_MS)
  waited = waited + POLL_MS
  if e and e:getHeader("Unique-ID") == uuid then
    local sub = e:getHeader("Event-Subclass") or ""
    if sub == EV .. "json" then
      local body = e:getBody() or ""
      raw   = (body:match('"AMDSTATUS"%s*:%s*"([^"]*)"') or "FAILED"):upper()
      cause = (body:match('"AMDCAUSE"%s*:%s*"([^"]*)"') or raw):upper()
      break
    elseif sub == EV .. "connect_failed" or sub == EV .. "error" then
      cause = "WS_" .. sub:match("::(.*)"):upper()
      break
    elseif sub == EV .. "disconnect" then
      cause = "WS_DISCONNECT"   -- server closed without a verdict
      break
    end
  end
end

-- The server closes the socket after replying; this is a no-op then, harmless if it logs.
api:executeString(CMD .. " " .. uuid .. " stop")

-- Same mapping as vmhunter.agi.py: keep the fine-grained reason in AMDCAUSE,
-- collapse the verdict to HUMAN/MACHINE for routing.
local status
if raw == "HUMAN" then
  status = "HUMAN"
elseif raw == "MACHINE" then
  status = "MACHINE"
elseif raw == "CALLGUARD" then
  status = CALLGUARD_AS
else
  status = FAILED_AS
end

session:setVariable("AMDSTATUS", status)
session:setVariable("AMDSTATUS_RAW", raw)
session:setVariable("AMDCAUSE", cause)
freeswitch.consoleLog("INFO", string.format(
  "[vmhunter] uuid=%s vid=%s module=%s raw=%s -> status=%s cause=%s waited=%dms\n",
  uuid, vid, module, raw, status, cause, waited))
