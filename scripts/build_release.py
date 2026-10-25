#!/usr/bin/env python3
"""Build signed Apple Silicon companion installers and token-free plugin packages."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOSTS = {
    "figma": {"source": "Figma-PhotoCraft", "version": "1.1.0", "build": "3", "minimum": "11.0",
              "app": "Figma PhotoCraft Bridge.app", "executable": "FigmaPhotoCraftBridge",
              "identity": "local.figma.photocraft.bridge", "plugin": ("manifest.json", "code.js", "ui.html")},
    "xd": {"source": "XD-Compositor", "version": "1.3.0", "build": "5", "minimum": "26.0",
           "app": "XD Compositor Bridge.app", "executable": "XDCompositorBridge",
           "identity": "local.xd.compositor.bridge", "plugin": ("manifest.json", "main.js")},
}


def run(arguments, **options):
    return subprocess.run([str(value) for value in arguments], check=True, **options)


def validate_sources(development=False):
    for host, info in HOSTS.items():
        plugin = ROOT / info["source"] / "plugin"
        manifest = json.loads((plugin / "manifest.json").read_text())
        files = {name: (plugin / name).read_bytes() for name in info["plugin"]}
        if any(re.search(rb'["\x27][a-f0-9]{64}["\x27]', content) for content in files.values()):
            raise ValueError("Plugin source contains a literal installation token: " + host)
        if any(b"__BRIDGE_TOKEN__" in content or b"__BRIDGE_URL__" in content for content in files.values()):
            raise ValueError("Plugin source still uses private installation placeholders: " + host)
        if host == "figma":
            if manifest.get("enablePrivatePluginApi") or b"figma.fileKey" in files["code.js"]:
                raise ValueError("The public Figma plugin must not use private APIs")
            if manifest.get("networkAccess", {}).get("allowedDomains") != ["http://localhost:47836"]:
                raise ValueError("Unexpected Figma localhost access scope")
            if not development and not re.fullmatch(r"[0-9]+", manifest.get("id", "")):
                raise ValueError("Set the Figma-assigned numeric plugin ID before a release build; use --development for a local test package")
            if not development and b"__BRIDGE_INSTALL_URL__" in files["ui.html"]:
                raise ValueError("Set the public companion download link before a release build")
        elif manifest.get("id") != "CmptXd01" or manifest.get("version") != info["version"]:
            raise ValueError("Unexpected XD plugin identity or release version")
    for name in ("shared/PSD.swift", "installer/Setup.swift", "LICENSE", "NOTICE", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"):
        if not (ROOT / name).is_file():
            raise ValueError("Missing release source: " + name)


def find_identity(explicit, ad_hoc):
    if ad_hoc:
        return "-"
    selected = explicit or os.environ.get("PHOTOCRAFT_SIGN_IDENTITY")
    result = run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True)
    available = re.findall(r'\b([A-F0-9]{40})\s+"(Developer ID Application:[^"\n]+)"', result.stdout)
    identities = [name for digest, name in available
                  if not selected or selected in (digest, name) or name.endswith("(" + selected + ")")]
    if len(identities) != 1:
        raise ValueError("Choose a Developer ID Application with --identity or PHOTOCRAFT_SIGN_IDENTITY; --ad-hoc is only for local development builds")
    return identities[0]


def sign(path, identity):
    options = ["--options", "runtime", "--timestamp"] if identity != "-" else []
    run(["codesign", "--force", "--sign", identity, *options, path])
    run(["codesign", "--verify", "--deep", "--strict", path])


def write_info(app, info):
    (app / "Contents").mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))


def build_icon(directory):
    source = ROOT / "assets/icon-512.png"
    if not source.exists():
        return None
    iconset = directory / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = "icon_" + str(size) + "x" + str(size) + ("@2x" if scale == 2 else "") + ".png"
            run(["sips", "-z", str(size * scale), str(size * scale), source, "--out", iconset / name], stdout=subprocess.DEVNULL)
    icon = directory / "AppIcon.icns"
    run(["iconutil", "-c", "icns", iconset, "-o", icon])
    return icon


def build_helper(host, directory, identity, icon=None):
    info = HOSTS[host]
    source = ROOT / info["source"]
    app = directory / info["app"]
    macos, resources = app / "Contents/MacOS", app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    metadata = {"CFBundleIdentifier": info["identity"], "CFBundleName": app.stem,
                     "CFBundleExecutable": info["executable"], "CFBundlePackageType": "APPL",
                     "CFBundleShortVersionString": info["version"], "CFBundleVersion": info["build"],
                "LSUIElement": True, "LSMinimumSystemVersion": info["minimum"]}
    if icon:
        shutil.copy2(icon, resources / icon.name)
        metadata["CFBundleIconFile"] = icon.name
    write_info(app, metadata)
    for name in ("LICENSE", "NOTICE", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(ROOT / name, resources / name)
    run(["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos" + info["minimum"],
         source / "bridge/main.swift", ROOT / "shared/PSD.swift", "-o", macos / info["executable"]])
    if host == "xd":
        run(["python3", source / "renderer/build.py", macos / "XDCompositorRenderer"])
        shutil.copy2(source / "renderer/vendor/LICENSE", resources / "Compositor-LICENSE")
        shutil.copy2(source / "renderer/SOURCE.txt", resources / "Renderer-SOURCE.txt")
        sign(macos / "XDCompositorRenderer", identity)
    sign(app, identity)
    return app


def build_setup(host, directory, helper, setup_binary, identity, icon=None):
    info = HOSTS[host]
    label = "Figma" if host == "figma" else "XD"
    app = directory / (label + " PhotoCraft Setup.app")
    macos, resources = app / "Contents/MacOS", app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(setup_binary, macos / "PhotoCraftSetup")
    shutil.copytree(helper, resources / helper.name)
    plugin = resources / "plugin"
    plugin.mkdir()
    for name in info["plugin"]:
        shutil.copy2(ROOT / info["source"] / "plugin" / name, plugin / name)
    for name in ("LICENSE", "NOTICE", "PRIVACY.md", "THIRD_PARTY_NOTICES.md", "README.md"):
        shutil.copy2(ROOT / name, resources / name)
    metadata = {"CFBundleIdentifier": "local.photocraft.setup." + host,
                     "CFBundleName": app.stem, "CFBundleExecutable": "PhotoCraftSetup", "CFBundlePackageType": "APPL",
                     "CFBundleShortVersionString": info["version"], "CFBundleVersion": info["build"],
                     "PhotoCraftHost": host, "LSUIElement": True, "LSMinimumSystemVersion": info["minimum"],
                "LSArchitecturePriority": ["arm64"]}
    if icon:
        shutil.copy2(icon, resources / icon.name)
        metadata["CFBundleIconFile"] = icon.name
    write_info(app, metadata)
    sign(app, identity)
    return app


def zip_app(app, output):
    output.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, output])


def package_plugin(host, output):
    info = HOSTS[host]
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in info["plugin"]:
            archive.write(ROOT / info["source"] / "plugin" / name, name)
        for name in ("LICENSE", "NOTICE"):
            archive.write(ROOT / name, name)
    with zipfile.ZipFile(output) as archive:
        expected = set(info["plugin"]) | {"LICENSE", "NOTICE"}
        if set(archive.namelist()) != expected or archive.testzip() is not None:
            raise ValueError("Plugin archive verification failed")


def notary_command(profile, action, *arguments, log_dir=None):
    result = subprocess.run(["xcrun", "notarytool", action, *map(str, arguments),
                             "--keychain-profile", profile, "--output-format", "json"],
                            capture_output=True, text=True)
    if log_dir is not None:
        log_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(log_dir, 0o700)
        stem = action + "-" + uuid.uuid4().hex
        for suffix, content in (("stdout", result.stdout), ("stderr", result.stderr)):
            descriptor = os.open(log_dir / (stem + "." + suffix), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                stream.write(content)
    for stream in (result.stdout, result.stderr):
        try:
            payload = json.loads(stream)
            if isinstance(payload, dict):
                payload["_exitCode"] = result.returncode
                return payload
        except ValueError:
            pass
    return {"_exitCode": result.returncode}


def submit_notarization(host, archive, profile, log_dir=None):
    result = notary_command(profile, "submit", archive, "--no-s3-acceleration", log_dir=log_dir)
    # Creating a submission precedes the upload. An ID in history alone does not
    # prove the archive reached Apple; only a successful submit may be resumed.
    if result.get("_exitCode") != 0:
        raise ValueError("Notary upload did not complete for " + host +
                         " (exit " + str(result.get("_exitCode")) + ")")
    submission_id = result.get("id")
    if not isinstance(submission_id, str) or not re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", submission_id):
        raise ValueError("Notary upload returned no valid submission ID for " + host)
    uuid.UUID(submission_id)
    print(json.dumps({"host": host, "notarizationId": submission_id, "status": "Uploaded"}), flush=True)
    return submission_id


def notarize(host, profile, submission_id, log_dir=None):
    uuid.UUID(submission_id)
    print(json.dumps({"host": host, "notarizationId": submission_id, "status": "Waiting"}), flush=True)
    for _ in range(12):
        result = notary_command(profile, "wait", submission_id, "--timeout", "10m", log_dir=log_dir)
        if not (result.get("_exitCode") == 0 and result.get("id") == submission_id and
                result.get("status") in ("Accepted", "Invalid", "Rejected")):
            result = notary_command(profile, "info", submission_id, log_dir=log_dir)
        status = result.get("status") if result.get("_exitCode") == 0 and result.get("id") == submission_id else None
        if status == "Accepted":
            print(json.dumps({"host": host, "notarizationId": submission_id, "status": status}), flush=True)
            return {"id": submission_id, "status": status}
        if status in ("Invalid", "Rejected"):
            raise ValueError("Apple rejected " + host + " submission " + submission_id)
        # A network failure while waiting does not invalidate an uploaded archive.
        time.sleep(3)
    raise ValueError("Notarization is still pending; resume " + host + "=" + submission_id)


def build(args):
    validate_sources(args.development)
    if args.validate_only:
        print(json.dumps({"sourcesValid": True, "development": args.development,
                          "versions": {host: info["version"] for host, info in HOSTS.items()}}, indent=2))
        return
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Release builds require an Apple Silicon Mac and Xcode command-line tools")
    if args.ad_hoc and not args.development:
        raise ValueError("Ad-hoc signing requires --development")
    if args.ad_hoc and args.notary_profile:
        raise ValueError("Notarization requires Developer ID signing")
    resumes = {}
    for value in getattr(args, "resume_notarization", []):
        host, separator, submission_id = value.partition("=")
        if host not in HOSTS or not separator:
            raise ValueError("Use --resume-notarization HOST=SUBMISSION_ID")
        uuid.UUID(submission_id)
        resumes[host] = submission_id
    if resumes and not args.notary_profile:
        raise ValueError("Resuming notarization requires --notary-profile")
    identity = find_identity(args.identity, args.ad_hoc)
    submissions = {}
    applications = {}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".photocraft-release-", dir=args.output.parent) as temporary:
        staging = Path(temporary)
        artifacts = staging / "artifacts"
        artifacts.mkdir()
        setup_binary = staging / "PhotoCraftSetup"
        run(["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos11.0", ROOT / "installer/Setup.swift", "-o", setup_binary])
        icon = build_icon(staging)
        for host, info in HOSTS.items():
            work = staging / host
            work.mkdir()
            helper = build_helper(host, work, identity, icon)
            app = build_setup(host, work, helper, setup_binary, identity, icon)
            label = "Figma" if host == "figma" else "XD"
            output = artifacts / ("PhotoCraft-Bridge-" + label + "-" + info["version"] + "-macOS-arm64.zip")
            zip_app(app, output)
            if args.notary_profile:
                submission_id = resumes.get(host) or submit_notarization(host, output, args.notary_profile,
                                                                         log_dir=staging / "notary-logs")
                submissions[host] = {"id": submission_id, "status": "In Progress"}
                applications[host] = (app, output)
        # Queue both hosts before waiting so Apple's independent scans can run in parallel.
        for host, (app, output) in applications.items():
            submissions[host] = notarize(host, args.notary_profile, submissions[host]["id"],
                                         log_dir=staging / "notary-logs")
            run(["xcrun", "stapler", "staple", app])
            run(["xcrun", "stapler", "validate", app])
            zip_app(app, output)
        package_plugin("xd", artifacts / ("PhotoCraft-Bridge-XD-" + HOSTS["xd"]["version"] + ".xdx"))
        figma_name = "PhotoCraft-Bridge-Figma-" + HOSTS["figma"]["version"] + "-plugin" + ("-development" if args.development else "") + ".zip"
        package_plugin("figma", artifacts / figma_name)
        report = {"development": args.development, "developerIdSigned": identity != "-",
                  "notarized": bool(args.notary_profile), "figmaCommunityReady": not args.development,
                  "notarizationSubmissions": submissions,
                  "artifacts": [{"name": path.name, "bytes": path.stat().st_size,
                                 "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                                for path in sorted(artifacts.iterdir())]}
        (artifacts / "release.json").write_text(json.dumps(report, indent=2) + "\n")
        args.output.mkdir(parents=True, exist_ok=True)
        for path in sorted(artifacts.iterdir()):
            os.replace(path, args.output / path.name)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--identity", help="Developer ID Application signing identity")
    parser.add_argument("--notary-profile", help="Existing notarytool keychain profile")
    parser.add_argument("--resume-notarization", action="append", default=[], metavar="HOST=ID",
                        help="Resume a confirmed uploaded figma or xd submission; stapling verifies the rebuilt code matches")
    parser.add_argument("--development", action="store_true", help="Allow the temporary local Figma ID and unfilled download link")
    parser.add_argument("--ad-hoc", action="store_true", help="Sign a local development build without Developer ID")
    parser.add_argument("--validate-only", action="store_true", help="Check release sources without compiling or writing artifacts")
    build(parser.parse_args())
