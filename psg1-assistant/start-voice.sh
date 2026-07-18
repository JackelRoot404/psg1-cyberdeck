#!/data/data/com.termux/files/usr/bin/bash
# PSG1 voice assistant launcher (offline STT). Needs: whisper.cpp built at ~/whisper.cpp,
# ggml-base.en.bin, termux-api + mic permission, ffmpeg, Shizuku running.
export PATH="$PREFIX/bin:$PATH"
export RISH_APPLICATION_ID=com.termux
termux-wake-lock 2>/dev/null
cd /data/local/tmp
exec taskset -c 4-7 python3 "$HOME/psg1-assistant/voice.py"
