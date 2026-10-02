# VM Hunter client for FreeSWITCH

A Lua script and a dialplan extension that stream the first seconds of a call to [VM Hunter](https://vmhunter.com) and set `AMDSTATUS` and `AMDCAUSE` on the channel. Works with `mod_audio_fork` (drachtio) or `mod_audio_stream`; it detects which one is loaded.

Full documentation: https://vmhunter.com/docs/freeswitch

## How it works

1. Originate the customer leg to the `vmhunter_amd` extension, so the script runs the moment the callee answers.
2. The script starts an audio fork to VM Hunter with the config frame as the module's metadata argument, then waits for the verdict event.
3. VM Hunter replies with one JSON verdict, normally about 2.3 seconds after the answer.
4. The script sets three channel variables and the dialplan transfers to `vmhunter_route`, which branches on them.

| Variable | Values | Use |
|---|---|---|
| `AMDSTATUS` | `HUMAN` or `MACHINE` | Route on this one |
| `AMDSTATUS_RAW` | `HUMAN`, `MACHINE`, `CALLGUARD`, `FAILED` | The server's verdict, untouched |
| `AMDCAUSE` | `HUMAN`, `MACHINE`, `MACHINE_BEEP`, `MACHINE_STATIC`, `DISCONNECT`, `INITIALSILENCE`, `MAXWORD`, `CALLGUARD_PHRASE:<phrase>`, ... | The reason. See the [API reference](https://vmhunter.com/docs/api). |

## Requirements

- FreeSWITCH with `mod_audio_fork` or `mod_audio_stream` loaded, and `mod_lua`.
- A VM Hunter API key (free tier: 5,000 calls a month): https://vmhunter.com/register

## Install

```bash
cp vmhunter_amd.lua /usr/share/freeswitch/scripts/          # or your scripts dir
cp vmhunter_amd.xml /etc/freeswitch/dialplan/default/        # or your dialer's context
fs_cli -x reloadxml
```

Set your API key as a global variable in `vars.xml`, or per call in the originate string:

```xml
<X-PRE-PROCESS cmd="set" data="vmhunter_api_key=your_api_key"/>
```

## Originate

```
originate {vid=12345,ignore_early_media=true,origination_caller_id_number=18005551212}sofia/gateway/carrier/15551234567 vmhunter_amd XML default
```

`vid` is the lead or call id the call is logged and recorded under. Any string is fine; it falls back to the channel UUID.

## Routing

`vmhunter_amd.xml` contains:

- `vmhunter_amd`: runs the script, logs the verdict, transfers to `vmhunter_route`.
- `vmhunter_route`: sends screened calls (`AMDCAUSE` starting `CALLGUARD`) to a short intro and then an agent; everything else goes to `vmhunter_${AMDSTATUS}`.
- `vmhunter_HUMAN`: hand the live person to your agents (a `callcenter` queue by default; change to your fifo or bridge).
- `vmhunter_MACHINE`: hang up, or give disconnected numbers (`AMDCAUSE=DISCONNECT`) their own disposition.

Edit the `vmhunter_HUMAN` and `vmhunter_MACHINE` extensions to match your dialer. If you want screened calls dropped instead of answered, remove the `CALLGUARD` condition from `vmhunter_route`.

## Variables read by the script

| Variable | Default | Meaning |
|---|---|---|
| `vmhunter_api_key` | (required) | Your API key |
| `vmhunter_ws_url` | `ws://app.vmhunter.com:2701` | Server |
| `vmhunter_module` | auto | `audio_fork` or `audio_stream` |
| `vid` | channel UUID | Lead or call id |

Inside the script, `CALLGUARD_AS` (default `HUMAN`) and `FAILED_AS` (default `MACHINE`) set what `AMDSTATUS` becomes for call screening and for server errors.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `AMDCAUSE=NOT_RUN` | The script exited before starting the fork: check that the module is loaded (`module_exists mod_audio_fork`) and the API key is set. |
| Every call is `INITIALSILENCE` | The fork is sending the wrong leg or no audio. The config uses the "mono 8k" far-end stream; check which leg your originate answers on. |
| Verdict never arrives | Outbound TCP to port 2701 is blocked, or the `mod_audio_fork::json` event is not reaching the script. |

## License

MIT. See `LICENSE`.
