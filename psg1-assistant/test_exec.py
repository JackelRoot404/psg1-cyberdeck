import sys, time; sys.path.insert(0, "/data/data/com.termux/files/home/psg1-assistant")
from executor import execute
print("get_battery      ->", execute("get_battery"))
print("get_status       ->", execute("get_status"))
print("toggle_wifi on   ->", execute("toggle_wifi", {"state":"on"}))   # safe (already on)
print("set_brightness 30->", execute("set_brightness", {"level":30}))
time.sleep(1); print("  status now       ->", execute("get_status"))
print("open_app settings->", execute("open_app", {"app":"settings"}))
print("[SECURITY] bad tool  ->", execute("rm_rf_home"))
print("[SECURITY] bad args  ->", execute("set_brightness", {"level":9999}))
execute("set_brightness", {"level":100})  # restore
print("=== EXEC TEST DONE ===")
