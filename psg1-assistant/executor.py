"""Safe device-control executor. The model NEVER gets a raw shell — it picks a tool
name from a fixed allowlist; each tool maps to a fixed rish command with only
validated (enum / int-range) args interpolated."""
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

def _onoff(a):
    st = a.get("state")
    return st if st in ("on", "off") else None

# --- original 5 ---
def get_battery(a):
    m = re.search(r"^\s*level:\s*(\d+)", _rish("dumpsys battery"), re.M)
    return f"Battery: {m.group(1)}%" if m else "Battery: unknown"

def toggle_wifi(a):
    st = _onoff(a)
    if not st: return "error: state must be 'on' or 'off'"
    _rish(f"svc wifi {'enable' if st == 'on' else 'disable'}")
    return f"WiFi turned {st}"

def set_brightness(a):
    lvl = a.get("level")
    if not isinstance(lvl, int) or not (0 <= lvl <= 100): return "error: level must be 0-100"
    _rish(f"settings put system screen_brightness {round(lvl*255/100)}")
    return f"Brightness set to {lvl}%"

def open_app(a):
    intents = {"camera":"am start -a android.media.action.STILL_IMAGE_CAMERA",
               "settings":"am start -a android.settings.SETTINGS",
               "browser":"am start -a android.intent.action.VIEW -d https://duckduckgo.com"}
    app = a.get("app")
    if app not in intents: return f"error: unknown app '{app}'"
    _rish(intents[app]); return f"Opened {app}"

def get_status(a):
    m = re.search(r"(\d+)", _rish("dumpsys battery | grep -m1 -i 'level:'"))
    wifi = _rish("settings get global wifi_on").strip()
    br = _rish("settings get system screen_brightness").strip()
    bp = round(int(br)/255*100) if br.isdigit() else "?"
    return f"Battery {m.group(1) if m else '?'}%, WiFi {'on' if wifi=='1' else 'off'}, Brightness {bp}%"

# --- 6 new ---
def toggle_bluetooth(a):
    st = _onoff(a)
    if not st: return "error: state must be 'on' or 'off'"
    _rish(f"svc bluetooth {'enable' if st == 'on' else 'disable'}")
    return f"Bluetooth turned {st}"

def set_volume(a):
    lvl = a.get("level")
    if not isinstance(lvl, int) or not (0 <= lvl <= 100): return "error: level must be 0-100"
    _rish(f"cmd media_session volume --stream 3 --set {round(lvl*15/100)}")  # STREAM_MUSIC ~0-15
    return f"Volume set to {lvl}%"

def lock_screen(a):
    _rish("input keyevent KEYCODE_POWER"); return "Screen locked"

def take_screenshot(a):
    path = "/sdcard/Pictures/psg1_screen.png"
    _rish(f"screencap -p {path}"); return f"Screenshot saved to {path}"

def go_home(a):
    _rish("input keyevent KEYCODE_HOME"); return "Went to the home screen"

def media_control(a):
    keys = {"play":"KEYCODE_MEDIA_PLAY_PAUSE","pause":"KEYCODE_MEDIA_PLAY_PAUSE",
            "next":"KEYCODE_MEDIA_NEXT","previous":"KEYCODE_MEDIA_PREVIOUS"}
    act = a.get("action")
    if act not in keys: return "error: action must be play/pause/next/previous"
    _rish(f"input keyevent {keys[act]}"); return f"Media: {act}"

TOOLS = {"get_battery":get_battery, "toggle_wifi":toggle_wifi, "set_brightness":set_brightness,
         "open_app":open_app, "get_status":get_status, "toggle_bluetooth":toggle_bluetooth,
         "set_volume":set_volume, "lock_screen":lock_screen, "take_screenshot":take_screenshot,
         "go_home":go_home, "media_control":media_control}

def execute(tool, args=None):
    fn = TOOLS.get(tool)
    return fn(args or {}) if fn else f"error: unknown tool '{tool}'"
