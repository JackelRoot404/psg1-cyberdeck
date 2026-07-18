#!/data/data/com.termux/files/usr/bin/bash
# PSG1 local assistant launcher. Needs: Shizuku running + Termux authorized (rish),
# and the model file present. Type requests; "quit" to exit.
export PATH="$PREFIX/bin:$PATH"
export RISH_APPLICATION_ID=com.termux
termux-wake-lock 2>/dev/null
cd /data/local/tmp    # rish-friendly cwd
exec taskset -c 4-7 python3 "$HOME/psg1-assistant/assistant.py"
