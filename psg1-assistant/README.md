# PSG1 local assistant

Natural-language device control, fully on-device. No cloud.

    bash ~/psg1-assistant/start.sh
    > set the brightness to 30 percent
    > open the settings app
    > quit

## Architecture
- **Brain:** Qwen2.5-1.5B-Instruct Q4_0 via **llama-cpp-python** (loads once, stays resident).
  llama-cli/llama-server segfault on this device; the Python bindings call libllama directly and work.
- **Reliability:** a **GBNF grammar** (tools.gbnf) forces output to `{"tool":<enum>,"args":{...}}` —
  malformed tool calls are impossible; only tool/arg *choice* is up to the model.
- **Hands:** **executor.py** maps each tool to a fixed **rish** (Shizuku shell-uid) command.
  The model NEVER gets a raw shell — only 5 allowlisted tools with validated enum/int args.

## Tools
get_battery · toggle_wifi{on/off} · set_brightness{0-100} · open_app{camera/settings/browser} · get_status

## Add a tool
1. Add a function + entry to `TOOLS` in executor.py (fixed command, validate args).
2. Add the tool name to `tool ::=` in tools.gbnf.
3. Mention it in the system prompt (SYS) in assistant.py.

## Caveats
- **Shizuku must be running and Termux authorized** (one-time rish grant). If rish times out,
  open Shizuku, ensure it's running, and disable battery optimization for Termux + Shizuku.
- **~4-5s per command** (1.5B on CPU). Usable, not instant. Model load is one-time (~1.5s).
- 1.5B is fluent but limited — reliable for these constrained intents, not open Q&A.
- Patched: llama_cpp/_ctypes_extensions.py maps sys.platform=="android" -> .so loader (py3.13+).
