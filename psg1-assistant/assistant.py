#!/data/data/com.termux/files/usr/bin/env python3
"""PSG1 local assistant: intent -> 1.5B (grammar-constrained tool JSON) -> safe rish executor.
Model loads ONCE and stays resident; a RAM cache keeps the system-prompt KV warm so it is
NOT reprocessed every turn (the main latency win — dotprod is already enabled)."""
import sys, json, time
sys.path.insert(0, "/data/data/com.termux/files/home/psg1-assistant")
from llama_cpp import Llama, LlamaGrammar, LlamaRAMCache
from executor import execute

MODEL = "/data/data/com.termux/files/home/qwen2.5-1.5b-instruct-q4_0.gguf"
GBNF  = "/data/data/com.termux/files/home/psg1-assistant/tools.gbnf"
SYS = ('You are a device controller. Reply ONLY with JSON {"tool":<name>,"args":{...}}. Tools:\n'
 'get_battery{} · toggle_wifi{state:on|off} · set_brightness{level:0-100} · '
 'open_app{app:camera|settings|browser} · get_status{} · toggle_bluetooth{state:on|off} · '
 'set_volume{level:0-100} · lock_screen{} · take_screenshot{} · go_home{} · '
 'media_control{action:play|pause|next|previous}')

def main():
    t0 = time.time()
    llm = Llama(model_path=MODEL, n_ctx=1024, n_threads=4, verbose=False)
    llm.set_cache(LlamaRAMCache(capacity_bytes=256*1024*1024))  # keep system-prompt prefix warm
    grammar = LlamaGrammar.from_string(open(GBNF).read())
    print(f"[ready in {time.time()-t0:.1f}s] PSG1 assistant ({len(execute.__globals__['TOOLS'])} tools). Type a request per line.", flush=True)
    for line in sys.stdin:
        user = line.strip()
        if not user: continue
        if user.lower() in ("quit", "exit"): break
        t = time.time()
        out = llm.create_chat_completion(
            messages=[{"role":"system","content":SYS},{"role":"user","content":user}],
            grammar=grammar, max_tokens=60, temperature=0.2)
        txt = out["choices"][0]["message"]["content"].strip()
        try:
            call = json.loads(txt)
            result = execute(call.get("tool"), call.get("args", {}))
        except Exception as e:
            result = f"error: could not parse/execute ({e})"
        print(f"  “{user}”\n     tool: {txt}\n     result: {result}   [{time.time()-t:.1f}s]", flush=True)

if __name__ == "__main__":
    main()
