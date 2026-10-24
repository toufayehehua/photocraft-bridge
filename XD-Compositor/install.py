#!/usr/bin/env python3
"""从源码或预构建应用安装 XD 桥接；公开插件不包含本机密钥。"""
from pathlib import Path
import argparse
import json
import os
import platform
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
from shortcut import configure

IDENTITY = "local.xd.compositor.bridge"
VERSION, BUILD = "1.3.0", "5"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def private_write(path, content):
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
        return config
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    return {"port": port, "token": secrets.token_hex(32)}


def app_info(app):
    if app.is_symlink():
        raise SystemExit("桥接程序路径不能是符号链接。")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != IDENTITY:
        raise SystemExit("桥接程序来源不符，未改动。")
    return info


def stage_app(root, app, staged, prebuilt):
    if prebuilt:
        info = app_info(prebuilt)
        if info.get("CFBundleShortVersionString") != VERSION or info.get("CFBundleVersion") != BUILD:
            raise SystemExit("预构建桥接程序版本不符。")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(prebuilt)], check=True)
        shutil.copytree(prebuilt, staged)
        return
    macos = staged / "Contents/MacOS"
    resources = staged / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(root / "renderer/vendor/LICENSE", resources / "Compositor-LICENSE")
    shutil.copy2(root / "renderer/SOURCE.txt", resources / "Renderer-SOURCE.txt")
    info = {"CFBundleIdentifier": IDENTITY, "CFBundleName": "XD Compositor Bridge",
            "CFBundleExecutable": "XDCompositorBridge", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD,
            "LSUIElement": True, "LSMinimumSystemVersion": "26.0"}
    (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos26.0",
                    str(root / "bridge/main.swift"), str(root.parent / "shared/PSD.swift"),
                    "-o", str(macos / "XDCompositorBridge")], check=True)
    subprocess.run(["python3", str(root / "renderer/build.py"), str(macos / "XDCompositorRenderer")], check=True)
    identity = os.environ.get("XD_COMPOSITOR_SIGN_IDENTITY")
    if identity is None and app.exists():
        signature = subprocess.run(["codesign", "--display", "--verbose=2", str(app)], capture_output=True, text=True)
        identity = next((line.removeprefix("Authority=") for line in signature.stderr.splitlines()
                         if line.startswith("Authority=Developer ID Application:")), None)
    identity = identity or "-"
    options = ["--options", "runtime", "--timestamp"] if identity != "-" else []
    # Nested executables must each carry a valid signature before the app is sealed.
    for executable in (macos / "XDCompositorRenderer", staged):
        subprocess.run(["codesign", "--force", "--sign", identity, *options, str(executable)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="使用预构建桥接应用，无需本机编译。")
    parser.add_argument("--pairing-code", action="store_true", help="仅显示已安装桥接的本机配对码。")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("当前安装程序适用于 Apple Silicon Mac。")
    root, home = Path(__file__).resolve().parent, Path.home()
    state = home / "Library/Application Support/XD-Compositor"
    config_file = state / "bridge-config.json"
    develop = home / "Library/Application Support/Adobe/Adobe XD/develop/Compositor"
    app = home / "Applications/XD Compositor Bridge.app"
    agent = home / "Library/LaunchAgents/local.xd.compositor.bridge.plist"
    for path in (state, config_file, develop, app, agent):
        if path.is_symlink():
            raise SystemExit("安装目标不能是符号链接。")
    if args.pairing_code:
        if not config_file.is_file():
            raise SystemExit("尚未安装 PhotoCraft 桥接组件。")
        config = load_config(config_file)
        print(str(config["port"]) + ":" + config["token"])
        return
    if int(platform.mac_ver()[0].split(".")[0]) < 26:
        raise SystemExit("自动渲染组件需要 macOS 26 或更高版本。")
    if develop.exists() and json.loads((develop / "manifest.json").read_text()).get("id") != "CmptXd01":
        raise SystemExit("目标插件目录已存在且来源不符，未改动。")
    if app.exists():
        app_info(app)
    if agent.exists() and plistlib.loads(agent.read_bytes()).get("Label") != IDENTITY:
        raise SystemExit("启动项已存在且来源不符，未改动。")
    config = load_config(config_file)
    domain = "gui/" + str(os.getuid())
    with tempfile.TemporaryDirectory(prefix="xd-compositor-build-") as temporary:
        staged = Path(temporary) / app.name
        stage_app(root, app, staged, args.app)
        subprocess.run(["launchctl", "bootout", domain, str(agent)], capture_output=True)
        app.parent.mkdir(parents=True, exist_ok=True)
        if app.exists():
            shutil.rmtree(app)
        shutil.copytree(staged, app)
    subprocess.run([LSREGISTER, "-f", str(app)], check=True)
    develop.mkdir(parents=True, exist_ok=True)
    for name in ("main.js", "manifest.json"):
        shutil.copy2(root / "plugin" / name, develop / name)
    # Remove the obsolete private-package secret after migrating to user data.
    (develop / "bridge-config.json").unlink(missing_ok=True)
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    private_write(config_file, json.dumps(config).encode())
    agent.parent.mkdir(parents=True, exist_ok=True)
    private_write(agent, plistlib.dumps({"Label": IDENTITY,
        "ProgramArguments": [str(app / "Contents/MacOS/XDCompositorBridge"), str(config_file)],
        "RunAtLoad": True, "KeepAlive": True, "ProcessType": "Interactive", "ThrottleInterval": 10}))
    subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
    configure(state)
    print(develop)
    print(app)


if __name__ == "__main__":
    main()
