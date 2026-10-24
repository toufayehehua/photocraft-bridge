"""管理 XD 专用的菜单快捷键，卸载时恢复原设置。"""
import json
import plistlib
import subprocess

DOMAIN = "com.adobe.xd"
MENU = "在 PhotoCraft 中编辑"
LEGACY_MENU = "在 Compositor 中编辑"
KEY = "@p"

def read_shortcuts():
    result = subprocess.run(["defaults", "read", DOMAIN, "NSUserKeyEquivalents"], capture_output=True)
    if result.returncode:
        return {}
    xml = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", "-"],
                         input=result.stdout, capture_output=True, check=True).stdout
    return plistlib.loads(xml)

def write_shortcuts(values):
    if values:
        arguments = [item for pair in values.items() for item in pair]
        subprocess.run(["defaults", "write", DOMAIN, "NSUserKeyEquivalents", "-dict", *arguments], check=True)
    else:
        subprocess.run(["defaults", "delete", DOMAIN, "NSUserKeyEquivalents"], check=True)

def restore_shortcut(values, menu, previous):
    if values.get(menu) != KEY:
        return
    if previous is None:
        values.pop(menu, None)
    else:
        values[menu] = previous
    write_shortcuts(values)

def configure(state):
    backup = state / "shortcut-backup.json"
    values = read_shortcuts()
    record = json.loads(backup.read_text()) if backup.exists() else None
    if record is not None and record.get("menu", LEGACY_MENU) != MENU:
        restore_shortcut(values, record.get("menu", LEGACY_MENU), record["previous"])
        record = None
    if record is None:
        backup.write_text(json.dumps({"menu": MENU, "previous": values.get(MENU)}, ensure_ascii=False))
    subprocess.run(["defaults", "write", DOMAIN, "NSUserKeyEquivalents", "-dict-add", MENU, KEY], check=True)

def restore(state):
    backup = state / "shortcut-backup.json"
    if not backup.exists():
        return
    record = json.loads(backup.read_text())
    restore_shortcut(read_shortcuts(), record.get("menu", LEGACY_MENU), record["previous"])
    backup.unlink()
