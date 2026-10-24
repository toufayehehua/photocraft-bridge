#!/usr/bin/env python3
"""卸载 Figma 桥接，保留所有工作图片和 PSD 工程。"""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess

IDENTITY = "local.figma.photocraft.bridge"
PLUGIN_ID = "1695793882852666354"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def main():
    home = Path.home()
    state = home / "Library/Application Support/Figma-PhotoCraft"
    plugin = state / "plugin"
    app = home / "Applications/Figma PhotoCraft Bridge.app"
    agent = home / "Library/LaunchAgents/local.figma.photocraft.bridge.plist"
    for path in (state, plugin, app, agent):
        if path.is_symlink():
            raise SystemExit("目标路径不能是符号链接，未卸载。")
    if app.exists() and plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier") != IDENTITY:
        raise SystemExit("桥接程序来源不符，未卸载。")
    if plugin.exists() and json.loads((plugin / "manifest.json").read_text()).get("id") != PLUGIN_ID:
        raise SystemExit("插件目录来源不符，未卸载。")
    if agent.exists() and plistlib.loads(agent.read_bytes()).get("Label") != IDENTITY:
        raise SystemExit("启动项来源不符，未卸载。")
    subprocess.run(["launchctl", "bootout", "gui/" + str(os.getuid()), str(agent)], capture_output=True)
    if app.exists():
        subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True)
        shutil.rmtree(app)
    if plugin.exists():
        shutil.rmtree(plugin)
    agent.unlink(missing_ok=True)
    for name in ("bridge-config.json", "jobs.json"):
        (state / name).unlink(missing_ok=True)
    if state.exists() and not any(state.iterdir()):
        state.rmdir()
    print("已卸载 Figma 桥接；工作图片和 PSD 工程已保留。")


if __name__ == "__main__":
    main()
