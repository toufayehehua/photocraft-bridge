#!/usr/bin/env python3
"""安装独立的 Figma → PhotoCraft 本机桥接，不改动 XD 桥接。"""
from pathlib import Path
import json
import os
import platform
import plistlib
import re
import secrets
import shutil
import subprocess
import tempfile

IDENTITY = "local.figma.photocraft.bridge"
PLUGIN_ID = "1695793882852666354"
EXECUTABLE = "FigmaPhotoCraftBridge"
BRIDGE_PORT = 47836
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def check_owned_app(app):
    if app.is_symlink():
        raise SystemExit("桥接应用路径不能是符号链接。")
    if app.exists() and plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier") != IDENTITY:
        raise SystemExit("桥接程序已存在且来源不符，未改动。")


def write_private(path, content):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            os.fchmod(output.fileno(), 0o600)
            output.write(content)
            output.flush()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def load_config(path):
    if path.exists():
        config = json.loads(path.read_text())
        if (type(config.get("port")) is not int or not 1024 <= config["port"] <= 65535
                or not re.fullmatch(r"[0-9a-f]{64}", config.get("token", ""))):
            raise SystemExit("现有桥接配置无效，未覆盖。")
        if config["port"] != BRIDGE_PORT:
            raise SystemExit("现有桥接使用其他端口，公开版本固定使用 47836；未覆盖现有客户端。")
        return config
    return {"port": BRIDGE_PORT, "token": secrets.token_hex(32)}


def signing_identity(app, home):
    explicit = os.environ.get("FIGMA_PHOTOCRAFT_SIGN_IDENTITY")
    if explicit:
        return explicit
    for candidate in (app, home / "Applications/XD Compositor Bridge.app"):
        if not candidate.exists():
            continue
        result = subprocess.run(["codesign", "--display", "--verbose=2", str(candidate)], capture_output=True, text=True)
        for line in result.stderr.splitlines():
            if line.startswith("Authority=Developer ID Application:"):
                return line.removeprefix("Authority=")
    return "-"


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("当前安装程序适用于 Apple Silicon Mac。")
    if int(platform.mac_ver()[0].split(".")[0]) < 11:
        raise SystemExit("桥接程序需要 macOS 11 或更高版本。")
    root, home = Path(__file__).resolve().parent, Path.home()
    state = home / "Library/Application Support/Figma-PhotoCraft"
    plugin = state / "plugin"
    app = home / "Applications/Figma PhotoCraft Bridge.app"
    agent = home / "Library/LaunchAgents/local.figma.photocraft.bridge.plist"
    config_path = state / "bridge-config.json"
    for path in (state, plugin, agent, config_path):
        if path.is_symlink():
            raise SystemExit("目标路径不能是符号链接。")
    config = load_config(config_path)
    check_owned_app(app)
    if agent.exists() and plistlib.loads(agent.read_bytes()).get("Label") != IDENTITY:
        raise SystemExit("启动项已存在且来源不符，未改动。")
    if plugin.exists() and json.loads((plugin / "manifest.json").read_text()).get("id") != PLUGIN_ID:
        raise SystemExit("插件安装目录已存在且来源不符，未改动。")
    template = root / "plugin"
    code = (template / "code.js").read_bytes()
    if b"__BRIDGE_URL__" in code or b"__BRIDGE_TOKEN__" in code:
        raise SystemExit("插件尚未更新为公开配对版本，未安装。")
    manifest = json.loads((template / "manifest.json").read_text())
    if manifest.get("id") != PLUGIN_ID:
        raise SystemExit("插件模板标识不符。")
    if manifest.get("networkAccess", {}).get("allowedDomains") != ["http://localhost:47836"]:
        raise SystemExit("插件的本机连接地址不符，未安装。")
    ui = (template / "ui.html").read_bytes()
    psd_source = root.parent / "shared/PSD.swift"
    if not psd_source.is_file():
        raise SystemExit("缺少共享 PSD 源码，未安装。")
    info = {"CFBundleIdentifier": IDENTITY, "CFBundleName": "Figma PhotoCraft Bridge",
            "CFBundleExecutable": EXECUTABLE, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "3",
            "LSUIElement": True, "LSMinimumSystemVersion": "11.0"}
    domain = "gui/" + str(os.getuid())
    with tempfile.TemporaryDirectory(prefix="figma-photocraft-build-") as temporary:
        staged = Path(temporary) / app.name
        staged_macos = staged / "Contents/MacOS"
        staged_macos.mkdir(parents=True)
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos11.0",
                        str(root / "bridge/main.swift"), str(psd_source),
                        "-o", str(staged_macos / EXECUTABLE)], check=True)
        identity = signing_identity(app, home)
        options = ["--options", "runtime", "--timestamp"] if identity != "-" else []
        subprocess.run(["codesign", "--force", "--sign", identity, *options, str(staged)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(staged)], check=True)
        subprocess.run(["launchctl", "bootout", domain, str(agent)], capture_output=True)
        app.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, app, dirs_exist_ok=True)
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    plugin.mkdir(exist_ok=True, mode=0o700)
    plugin.chmod(0o700)
    write_private(config_path, json.dumps(config).encode())
    write_private(plugin / "code.js", code)
    write_private(plugin / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode())
    write_private(plugin / "ui.html", ui)
    agent.parent.mkdir(parents=True, exist_ok=True)
    write_private(agent, plistlib.dumps({"Label": IDENTITY,
        "ProgramArguments": [str(app / "Contents/MacOS" / EXECUTABLE), str(config_path)],
        "RunAtLoad": True, "KeepAlive": True, "ProcessType": "Interactive", "ThrottleInterval": 10}))
    subprocess.run([LSREGISTER, "-f", str(app)], check=True)
    subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
    subprocess.run(["open", str(app)], check=True)
    print(plugin)
    print(app)


if __name__ == "__main__":
    main()
