#!/usr/bin/env python3
"""卸载本插件和桥接组件，保留编辑图片。"""
from pathlib import Path
import os
import json
import plistlib
import shutil
import subprocess
from shortcut import restore

home = Path.home()
plugin = home / "Library/Application Support/Adobe/Adobe XD/develop/Compositor"
app = home / "Applications/XD Compositor Bridge.app"
agent = home / "Library/LaunchAgents/local.xd.compositor.bridge.plist"
config = home / "Library/Application Support/XD-Compositor/bridge-config.json"
if plugin.exists() and json.loads((plugin / "manifest.json").read_text())["id"] != "CmptXd01":
    raise SystemExit("插件目录来源不符，未卸载。")
if app.exists() and plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"] != "local.xd.compositor.bridge":
    raise SystemExit("桥接程序来源不符，未卸载。")
if agent.exists() and plistlib.loads(agent.read_bytes())["Label"] != "local.xd.compositor.bridge":
    raise SystemExit("启动项来源不符，未卸载。")
restore(config.parent)
subprocess.run(["launchctl", "bootout", "gui/" + str(os.getuid()), str(agent)], capture_output=True)
if app.exists():
    subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-u", str(app)], capture_output=True)
    shutil.rmtree(app)
if plugin.exists():
    shutil.rmtree(plugin)
agent.unlink(missing_ok=True)
config.unlink(missing_ok=True)
(config.parent / "jobs.json").unlink(missing_ok=True)
if config.parent.exists() and not any(config.parent.iterdir()):
    config.parent.rmdir()
print("已卸载插件和桥接组件；工作图片已保留。")
