"""Safe device-control executor. The model NEVER gets a raw shell — it picks a
tool name from a fixed allowlist; each tool maps to a fixed rish command with
only validated (enum / int-range) args interpolated."""
import subprocess, os, re
RISH = os.path.join(os.path.expanduser("~"), "psg1-assistant", "rish")
ENV = {**os.environ, "RISH_APPLICATION_ID": "com.termux"}

def _rish(cmd, timeout=12):
    try:
        p = subprocess.run([RISH, "-c", cmd], capture_output=True, text=True,
                           timeout=timeout, env=ENV, cwd="/data/local/tmp")
        return (p.stdout + p.stderr).strip()
    except Exception as e:
        return f"__error__ {e}"

def get_battery(a):
    m = re.search(r"^\s*level:\s*(\d+)", _rish("dumpsys battery"), re.M)
    return f"Battery: {m.group(1)}%" if m else "Battery: unknown"

def toggle_wifi(a):
    st = a.get("state")
    if st not in ("on", "off"): return "error: state must be 'on' or 'off'"
    _rish(f"svc wifi {'enable' if st == 'on' else 'disable'}")   # enum -> fixed verb
    return f"WiFi turned {st}"

def set_brightness(a):
    lvl = a.get("level")
    if not isinstance(lvl, int) or not (0 <= lvl <= 100): return "error: level must be 0-100"
    _rish(f"settings put system screen_brightness {round(lvl*255/100)}")  # validated int only
    return f"Brightness set to {lvl}%"

def open_app(a):
    intents = {
        "camera":   "am start -a android.media.action.STILL_IMAGE_CAMERA",
        "settings": "am start -a android.settings.SETTINGS",
        "browser":  "am start -a android.intent.action.VIEW -d https://duckduckgo.com",
    }
    app = a.get("app")
    if app not in intents: return f"error: unknown app '{app}'"
    _rish(intents[app])
    return f"Opened {app}"

def get_status(a):
    m = re.search(r"(\d+)", _rish("dumpsys battery | grep -m1 -i 'level:'"))
    wifi = _rish("settings get global wifi_on").strip()
    br = _rish("settings get system screen_brightness").strip()
    bp = round(int(br)/255*100) if br.isdigit() else "?"
    return f"Battery {m.group(1) if m else '?'}%, WiFi {'on' if wifi=='1' else 'off'}, Brightness {bp}%"

TOOLS = {"get_battery": get_battery, "toggle_wifi": toggle_wifi,
         "set_brightness": set_brightness, "open_app": open_app, "get_status": get_status}

def execute(tool, args=None):
    fn = TOOLS.get(tool)
    return fn(args or {}) if fn else f"error: unknown tool '{tool}'"
