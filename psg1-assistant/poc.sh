#!/data/data/com.termux/files/usr/bin/bash
export PATH="$PREFIX/bin:$PATH"
DIR="$HOME/psg1-assistant"
CLI="$HOME/llama.cpp/build/bin/llama-cli"
M="$HOME/qwen2.5-1.5b-instruct-q4_0.gguf"
SYS='You are a device controller. Choose exactly ONE tool for the user request and reply ONLY with JSON {"tool":<name>,"args":{...}}. Tools: get_battery (args {}), toggle_wifi (args {"state":"on" or "off"}), set_brightness (args {"level":0-100}), open_app (args {"app":"camera"|"settings"|"browser"}), get_status (args {}).'
run(){
  local u="$1"
  local p="<|im_start|>system
${SYS}<|im_end|>
<|im_start|>user
${u}<|im_end|>
<|im_start|>assistant
"
  local t0=$(date +%s)
  local out=$(taskset -c 4-7 "$CLI" -m "$M" -t 4 --grammar-file "$DIR/tools.gbnf" \
      -p "$p" -n 60 --no-display-prompt --no-warmup 2>/dev/null | tr -d "\r")
  local dt=$(( $(date +%s) - t0 ))
  echo "USER: $u"
  echo "  JSON: $out"
  echo "$out" | python3 -c "import json,sys;json.load(sys.stdin);print(\"  valid: YES\")" 2>/dev/null || echo "  valid: NO"
  echo "  latency: ${dt}s (incl model load)"
}
echo "=== llama-cli + grammar PoC $(date +%T) ==="
run "turn on the wifi"
run "how much battery is left"
run "dim the screen to 25 percent"
echo "=== DONE ==="
