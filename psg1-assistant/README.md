# PSG1 local assistant

Natural-language device control, fully on-device. No cloud.

    psg1            # or: bash ~/psg1-assistant/start.sh
    > set the brightness to 30 percent
    > take a screenshot
    > quit

## Architecture
- **Brain:** Qwen2.5-1.5B-Instruct Q4_0 via **llama-cpp-python** (loads once, stays resident,
  with a RAM cache so the system-prompt KV isn't reprocessed each turn). llama-cli/llama-server
  segfault on this device; the Python bindings call libllama directly and work. dotprod + Q4_0
  repack are enabled (verified: DOTPROD=1).
- **Reliability:** a **GBNF grammar** (tools.gbnf) forces `{"tool":<enum>,"args":{...}}` — malformed
  tool calls are impossible; only tool/arg *choice* is the model's.
- **Hands:** **executor.py** maps each tool to a fixed **rish** (Shizuku shell-uid) command. The
  model NEVER gets a raw shell — only allowlisted tools with validated enum/int args.

## Tools (11)
get_battery · toggle_wifi{on/off} · set_brightness{0-100} · open_app{camera/settings/browser} ·
get_status · toggle_bluetooth{on/off} · set_volume{0-100} · lock_screen · take_screenshot ·
go_home · media_control{play/pause/next/previous}

## Add a tool
1. Add a function + `TOOLS` entry in executor.py (fixed command; validate args).
2. Add the tool name to `tool ::=` in tools.gbnf.
3. Add it to the tool list in the `SYS` prompt in assistant.py.

## Speed
- ~4s/command steady (first is ~9s: model warmup). Load ~1.5s. Generation ~7 t/s (CPU,
  memory-bandwidth-bound — a smaller model is the only lever for faster gen). The system-prompt
  prefill is cached across turns. Multi-read tools (get_status) cost one rish spawn per read (~1s each).

## Caveats
- **Shizuku must be running and Termux authorized** (one-time rish grant). If rish times out, open
  Shizuku, ensure it's running, and disable battery optimization for Termux + Shizuku.
- 1.5B is fluent but limited — reliable for these constrained intents, not open Q&A.
- Not committed (provide locally): rish/rish_shizuku.dex (from the Shizuku APK), *.gguf, run logs.
- Patched: llama_cpp/_ctypes_extensions.py maps sys.platform=="android" -> .so loader (py3.13+).
