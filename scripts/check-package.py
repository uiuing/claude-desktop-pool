#!/usr/bin/env python3
"""Validate the local app artifact without launching it."""
import json
import os
import pathlib
import plistlib
import re
import subprocess


def unexpected_build_paths(application, upstream):
    paths = lambda data: set(re.findall(rb"/Users/[^\0\r\n]*", data))
    return paths(application) - paths(upstream)


root = pathlib.Path(__file__).resolve().parent.parent
app = root / "dist" / "Claude Pool.app"
info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
assert not info.get("LSUIElement", False) and not info.get("LSBackgroundOnly", False), "Application must be visible in the Dock and app switcher"
binary = app / "Contents" / "MacOS" / info["CFBundleExecutable"]
assert binary.is_file(), "Application executable is missing"
architectures = set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split())
assert architectures and architectures <= {"arm64", "x86_64"}, "Unexpected application architecture"
default_build = ".build/package-universal" if len(architectures) == 2 else ".build/package"
build_root = root / os.environ.get("POOL_BUILD_ROOT", default_build)
runtime = build_root / "artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime"
assert runtime.is_file(), "The verified ONNX Runtime build artifact is missing; set POOL_BUILD_ROOT to the package build directory"
# The pinned upstream binary contains its publisher's __FILE__ paths. Only exact
# strings from that SwiftPM-verified artifact are allowed in the final executable.
assert not unexpected_build_paths(binary.read_bytes(), runtime.read_bytes()), "Application contains a build-machine path outside the pinned runtime"
resources = app / "Contents" / "Resources" / "ClaudeDesktopPool_PoolCore.bundle"
# SwiftPM writes a flat bundle or, on newer toolchains, a standard one with Contents/Resources.
catalogs = next((path for path in (resources / "Contents" / "Resources" / "Localizations", resources / "Localizations") if path.is_dir()),
                resources / "Localizations")
for language in ("en", "zh-Hans", "zh-Hant", "ja", "ko"):
    catalog = json.loads((catalogs / f"{language}.json").read_text())
    assert catalog, f"Missing {language} catalog"
assert (app / "Contents" / "Resources" / "AppIcon.icns").is_file(), "Application icon is missing"
assert (app / "Contents" / "Resources" / "THIRD_PARTY_NOTICES.md").is_file(), "Third-party notices are missing"
for source in (root / "Resources" / "Licenses").rglob("*"):
    if source.is_file():
        installed = app / "Contents" / "Resources" / source.relative_to(root / "Resources")
        assert installed.is_file() and installed.read_bytes() == source.read_bytes(), "A bundled license differs from its source"
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print(f"Package resources, signature, build-path and architecture checks passed ({', '.join(sorted(architectures))}). Notarization is a separate release gate.")
