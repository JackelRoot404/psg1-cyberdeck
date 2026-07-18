#!/data/data/com.termux/files/usr/bin/env python3
"""PSG1 voice assistant — fully offline. Mic -> whisper.cpp (STT) -> 1.5B (grammar) -> rish.
No audio ever leaves the deck. Press Enter, speak a command (~4s), it runs."""
import subprocess, os, time, json, sys
sys.path.insert(0, "/data/data/com.termux/files/home/psg1-assistant")
from llama_cpp import Llama, LlamaGrammar, LlamaRAMCache
from executor import execute

H = os.path.expanduser("~")
WHISPER, WMODEL = f"{H}/whisper.cpp/build/bin/whisper-cli", f"{H}/whisper.cpp/models/ggml-base.en.bin"
REC = f"{H}/psg1-assistant/rec"
MODEL, GBNF = f"{H}/qwen2.5-1.5b-instruct-q4_0.gguf", f"{H}/psg1-assistant/tools.gbnf"
SYS = ('You are a device controller. Reply ONLY with JSON {"tool":<name>,"args":{...}}. Tools:\n'
 'get_battery{} · toggle_wifi{state:on|off} · set_brightness{level:0-100} · '
 'open_app{app:camera|settings|browser} · get_status{} · toggle_bluetooth{state:on|off} · '
 'set_volume{level:0-100} · lock_screen{} · take_screenshot{} · go_home{} · '
 'media_control{action:play|pause|next|previous}')
JUNK = {"", "you", "[blank_audio]", "[ silence ]", "(silence)", "thank you.", "."}

def listen(secs=4):
    subprocess.run(["termux-microphone-record", "-q"], capture_output=True)
    subprocess.run(["termux-microphone-record", "-f", f"{REC}.m4a", "-l", str(secs),
                    "-e", "aac", "-r", "16000", "-c", "1"], capture_output=True)
    time.sleep(secs + 0.4)
    subprocess.run(["termux-microphone-record", "-q"], capture_output=True)
    subprocess.run(["ffmpeg", "-y", "-i", f"{REC}.m4a", "-ar", "16000", "-ac", "1", f"{REC}.wav"], capture_output=True)
    r = subprocess.run([WHISPER, "-m", WMODEL, "-f", f"{REC}.wav", "-nt", "-t", "4"], capture_output=True, text=True)
    return r.stdout.strip()

def main():
    t0 = time.time()
    llm = Llama(model_path=MODEL, n_ctx=1024, n_threads=4, verbose=False)
    llm.set_cache(LlamaRAMCache(capacity_bytes=256*1024*1024))
    grammar = LlamaGrammar.from_string(open(GBNF).read())
    print(f"[ready in {time.time()-t0:.1f}s] PSG1 VOICE assistant. Press Enter, then speak a command (~4s). Ctrl-C to quit.", flush=True)
    for _ in sys.stdin:
        print("  [listening ~4s...]", flush=True)
        text = listen(4)
        if text.lower().strip() in JUNK:
            print("  (didn't catch a command)", flush=True); continue
        print(f'  heard: "{text}"', flush=True)
        t = time.time()
        out = llm.create_chat_completion(messages=[{"role":"system","content":SYS},{"role":"user","content":text}],
                                         grammar=grammar, max_tokens=60, temperature=0.2)
        txt = out["choices"][0]["message"]["content"].strip()
        try:
            call = json.loads(txt); result = execute(call.get("tool"), call.get("args", {}))
        except Exception as e:
            result = f"error: {e}"
        print(f"     tool: {txt}\n     result: {result}   [{time.time()-t:.1f}s]", flush=True)

if __name__ == "__main__":
    main()
