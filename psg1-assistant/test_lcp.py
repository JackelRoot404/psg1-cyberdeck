import time, json
from llama_cpp import Llama, LlamaGrammar
MODEL="/data/data/com.termux/files/home/qwen2.5-1.5b-instruct-q4_0.gguf"
GBNF="/data/data/com.termux/files/home/psg1-assistant/tools.gbnf"
t0=time.time()
llm=Llama(model_path=MODEL, n_ctx=1024, n_threads=4, verbose=False)
print(f"LOADED in {time.time()-t0:.1f}s", flush=True)
grammar=LlamaGrammar.from_string(open(GBNF).read())
SYS=('You are a device controller. Choose exactly ONE tool for the user request and reply ONLY with '
 'JSON {"tool":<name>,"args":{...}}. Tools: get_battery (args {}), toggle_wifi (args {"state":"on" or "off"}), '
 'set_brightness (args {"level":0-100}), open_app (args {"app":"camera"|"settings"|"browser"}), get_status (args {}).')
def isjson(s):
    try: json.loads(s); return True
    except Exception: return False
for user in ["turn on the wifi","how much battery is left","dim the screen to 25 percent"]:
    t=time.time()
    out=llm.create_chat_completion(messages=[{"role":"system","content":SYS},{"role":"user","content":user}],
        grammar=grammar, max_tokens=60, temperature=0.2)
    dt=time.time()-t
    txt=out["choices"][0]["message"]["content"].strip()
    tok=out["usage"]["completion_tokens"]
    print(f"USER: {user}\n  JSON: {txt}\n  valid={'YES' if isjson(txt) else 'NO'}  {tok}tok/{dt:.1f}s = {tok/max(dt,0.01):.1f} t/s", flush=True)
print("=== TEST DONE ===")
