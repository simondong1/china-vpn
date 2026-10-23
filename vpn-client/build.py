#!/usr/bin/env python3
"""
Build script for macOS VPN client.
Compiles Xray from source, builds the app with XcodeGen, signs it, and creates a DMG.

Requirements:
- macOS with Xcode 15+
- Python 3.8+
- Go 1.21+ (for building Xray)
- XcodeGen: brew install xcodegen
- create-dmg: brew install create-dmg

Environment variables for signing:
- APPLE_TEAM_ID: Your Apple Developer Team ID
- APPLE_CERT_NAME: Name of signing certificate (e.g., "Developer ID Application: Your Name (TEAMID)")
- Or leave unset for unsigned build (requires SIP disabled on target Mac)
"""

import os
import sys
import subprocess
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).parent
BUILD_DIR = REPO_ROOT / "build"
XRAY_DIR = BUILD_DIR / "xray-core"
XRAY_VERSION = "v26.10.21"

def run(cmd, cwd=None, check=True):
    """Run command and print output."""
    print(f"$ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, check=False, text=True)
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if check and result.returncode != 0:
        print(f"Error: command exited with code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)
    return result

def check_requirements():
    """Verify required tools are installed."""
    tools = {
        "xcodegen": "brew install xcodegen",
        "go": "Install from https://go.dev/dl/",
        "create-dmg": "brew install create-dmg"
    }

    missing = []
    for tool, install_cmd in tools.items():
        if shutil.which(tool) is None:
            missing.append(f"{tool}: {install_cmd}")

    if missing:
        print("Missing required tools:")
        for m in missing:
            print(f"  - {m}")
        sys.exit(1)

def build_xray():
    """Build Xray-core binary."""
    print(f"\n==> Building Xray {XRAY_VERSION}")

    BUILD_DIR.mkdir(exist_ok=True)

    if not XRAY_DIR.exists():
        run(["git", "clone", "--depth", "1", "--branch", XRAY_VERSION,
             "https://github.com/XTLS/Xray-core.git", str(XRAY_DIR)])

    # Build for macOS
    env = os.environ.copy()
    env.update({
        "CGO_ENABLED": "0",
        "GOOS": "darwin",
        "GOARCH": "amd64"
    })

    print("Building Xray for amd64...")
    result = subprocess.run(
        ["go", "build", "-o", str(BUILD_DIR / "xray_amd64"),
         "-trimpath", "-ldflags", "-s -w"],
        cwd=XRAY_DIR / "main",
        env=env
    )
    if result.returncode != 0:
        print(f"Failed to build xray_amd64 (exit code {result.returncode})", file=sys.stderr)
        sys.exit(1)

    # Build for Apple Silicon
    env["GOARCH"] = "arm64"
    print("Building Xray for arm64...")
    result = subprocess.run(
        ["go", "build", "-o", str(BUILD_DIR / "xray_arm64"),
         "-trimpath", "-ldflags", "-s -w"],
        cwd=XRAY_DIR / "main",
        env=env
    )
    if result.returncode != 0:
        print(f"Failed to build xray_arm64 (exit code {result.returncode})", file=sys.stderr)
        sys.exit(1)

    # Create universal binary
    xray_universal = BUILD_DIR / "xray"
    run(["lipo", "-create", "-output", str(xray_universal),
         str(BUILD_DIR / "xray_amd64"),
         str(BUILD_DIR / "xray_arm64")])

    xray_universal.chmod(0o755)
    print(f"✓ Built universal Xray binary: {xray_universal}")
    return xray_universal

def generate_xcode_project():
    """Generate Xcode project from project.yml."""
    print("\n==> Generating Xcode project")
    run(["xcodegen", "generate"], cwd=REPO_ROOT)
    print("✓ Generated VPN.xcodeproj")

def build_app(xray_binary):
    """Build the app with xcodebuild."""
    print("\n==> Building VPN.app")

    # Copy xray binary into extension bundle
    resources_dir = REPO_ROOT / "VPNExtension" / "Resources"
    resources_dir.mkdir(exist_ok=True)
    shutil.copy(xray_binary, resources_dir / "xray")

    # Build parameters
    scheme = "VPN"
    configuration = "Release"
    archive_path = BUILD_DIR / "VPN.xcarchive"

    team_id = os.getenv("APPLE_TEAM_ID")
    cert_name = os.getenv("APPLE_CERT_NAME")

    build_cmd = [
        "xcodebuild",
        "-project", "VPN.xcodeproj",
        "-scheme", scheme,
        "-configuration", configuration,
        "-archivePath", str(archive_path),
        "archive"
    ]

    if team_id and cert_name:
        print(f"✓ Signing with team {team_id}")
        build_cmd.extend([
            f"CODE_SIGN_STYLE=Manual",
            f"DEVELOPMENT_TEAM={team_id}",
            f"CODE_SIGN_IDENTITY={cert_name}"
        ])
    else:
        print("⚠️  Building unsigned (SIP must be disabled on target Mac)")
        build_cmd.extend([
            "CODE_SIGN_IDENTITY=-",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGNING_ALLOWED=NO"
        ])

    run(build_cmd, cwd=REPO_ROOT)

    # Export app
    export_dir = BUILD_DIR / "export"
    export_dir.mkdir(exist_ok=True)

    app_path = archive_path / "Products" / "Applications" / "VPN.app"
    export_app = export_dir / "VPN.app"

    if export_app.exists():
        shutil.rmtree(export_app)

    shutil.copytree(app_path, export_app, symlinks=True)

    print(f"✓ Built app: {export_app}")
    return export_app

def create_dmg(app_path):
    """Create distributable DMG."""
    print("\n==> Creating DMG")

    dmg_path = REPO_ROOT / "VPN.dmg"
    if dmg_path.exists():
        dmg_path.unlink()

    run([
        "create-dmg",
        "--volname", "VPN",
        "--window-pos", "200", "120",
        "--window-size", "600", "400",
        "--icon-size", "100",
        "--app-drop-link", "450", "185",
        str(dmg_path),
        str(app_path)
    ], check=False)  # create-dmg returns non-zero even on success

    if dmg_path.exists():
        size_mb = dmg_path.stat().st_size / (1024 * 1024)
        print(f"✓ Created DMG: {dmg_path} ({size_mb:.1f} MB)")
        return dmg_path
    else:
        print("✗ DMG creation failed")
        sys.exit(1)

def main():
    print("Building macOS VPN client")
    print("=" * 60)

    check_requirements()
    xray_binary = build_xray()
    generate_xcode_project()
    app_path = build_app(xray_binary)
    dmg_path = create_dmg(app_path)

    print("\n" + "=" * 60)
    print("Build complete!")
    print(f"DMG: {dmg_path}")
    print("\nTo install on your Mac in China:")
    print("1. Transfer VPN.dmg to the Mac")
    print("2. Open it and drag VPN.app to Applications")
    if not os.getenv("APPLE_TEAM_ID"):
        print("3. Disable SIP: csrutil disable (in Recovery Mode)")
        print("4. Right-click app → Open (to bypass Gatekeeper)")
    else:
        print("3. Open the app from Applications")

if __name__ == "__main__":
    main()
