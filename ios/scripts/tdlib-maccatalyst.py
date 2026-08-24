#!/usr/bin/env python3
"""Add a Mac Catalyst slice to the resolved TDLibFramework.xcframework.

Why this exists
---------------
`Swiftgram/TDLibFramework` ships slices for ios, ios-simulator, macos, tvos,
watchos and xros — but not `ios-*-maccatalyst`. Mac Catalyst links against the
`arm64-apple-ios-macabi` triple, so the macos slice is rejected outright:

    ld: building for 'macCatalyst', but linking in object file
        (…TDLibFramework[arm64][3](ConcurrentScheduler.cpp.o)) built for 'macOS'

TDLib itself is platform-agnostic C++ (no AppKit, no UIKit — it reaches only
libc++, libz and BSD sockets), so the macos objects *are* correct code for
macabi; only the `LC_BUILD_VERSION` platform stamp disagrees. This script
copies the macos slice, rewrites that stamp in place — PLATFORM_MACOS (1) →
PLATFORM_MACCATALYST (6), minos lowered so nothing links "too new" — and
registers the copy in the xcframework's Info.plist as
`ios-arm64_x86_64-maccatalyst`.

Nothing but four bytes per load command changes: the archive layout, its
symbol table and every member's contents are untouched, so the result is the
same code the iOS build links, wearing the platform label the Catalyst linker
requires.

Idempotent: a second run sees the slice and exits. Safe to delete the slice
(or the whole DerivedData) — the next `make mac-build` recreates it.

Usage: tdlib-maccatalyst.py <path/to/SourcePackages>

The argument is the `-clonedSourcePackagesDirPath` directory, not the
xcframework: SwiftPM records the artifact's *absolute* path in
`workspace-state.json`, and a state file carried over from another checkout
(or another machine) points the build at an xcframework this script never
touched. Given the directory, the script can spot that mismatch, repoint the
state at the artifact that actually lives here, and patch the one the build
will really open.
"""

import plistlib
import shutil
import struct
import sys
from pathlib import Path

SLICE_ID = "ios-arm64_x86_64-maccatalyst"
SOURCE_ID = "macos-arm64_x86_64"

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32

PLATFORM_MACOS = 1
PLATFORM_MACCATALYST = 6
# Version words are packed X.Y.Z as 0xXXXXYYZZ. 13.0 is the first Catalyst
# release, so no object can be "newer than" the app being linked.
MINOS = 13 << 16
SDK = 17 << 16

AR_MAGIC = b"!<arch>\n"
AR_HEADER = 60

ARTIFACT_SUBPATH = Path("artifacts/tdlibframework/TDLibFramework/TDLibFramework.xcframework")


def patch_macho(buf: bytearray, base: int) -> int:
    """Rewrite every macOS LC_BUILD_VERSION in the Mach-O at `base`. Returns the count."""
    magic = struct.unpack_from("<I", buf, base)[0]
    if magic != MH_MAGIC_64:
        return 0
    ncmds = struct.unpack_from("<I", buf, base + 16)[0]
    offset = base + 32  # mach_header_64
    patched = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, offset)
        if cmdsize == 0:
            break
        if cmd == LC_BUILD_VERSION:
            platform = struct.unpack_from("<I", buf, offset + 8)[0]
            if platform == PLATFORM_MACOS:
                struct.pack_into("<III", buf, offset + 8, PLATFORM_MACCATALYST, MINOS, SDK)
                patched += 1
        offset += cmdsize
    return patched


def patch_archive(buf: bytearray, base: int, size: int) -> int:
    """Walk a BSD `ar` archive in place, patching each Mach-O member."""
    if bytes(buf[base:base + len(AR_MAGIC)]) != AR_MAGIC:
        # Not an archive — a bare Mach-O slice.
        return patch_macho(buf, base)
    offset = base + len(AR_MAGIC)
    end = base + size
    patched = 0
    while offset + AR_HEADER <= end:
        name = bytes(buf[offset:offset + 16])
        raw_size = bytes(buf[offset + 48:offset + 58]).strip()
        if not raw_size.isdigit():
            break
        member_size = int(raw_size)
        data = offset + AR_HEADER
        # BSD long names live in the first N bytes of the member data.
        if name.startswith(b"#1/"):
            data += int(name[3:].strip())
        if data < end:
            patched += patch_macho(buf, data)
        offset = offset + AR_HEADER + member_size
        if member_size % 2:
            offset += 1
    return patched


def patch_binary(path: Path) -> int:
    buf = bytearray(path.read_bytes())
    magic = struct.unpack_from(">I", buf, 0)[0]
    patched = 0
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        wide = magic == FAT_MAGIC_64
        nfat = struct.unpack_from(">I", buf, 4)[0]
        entry = 32 if wide else 20
        for i in range(nfat):
            head = 8 + i * entry
            if wide:
                offset, size = struct.unpack_from(">QQ", buf, head + 8)
            else:
                offset, size = struct.unpack_from(">II", buf, head + 8)
            patched += patch_archive(buf, offset, size)
    else:
        patched += patch_archive(buf, 0, len(buf))
    path.write_bytes(bytes(buf))
    return patched


def effective_xcframework(packages: Path) -> Path:
    """The xcframework this build will actually open, repairing a stale state path."""
    # Absolute: SwiftPM stores absolute artifact paths, and a relative one reads
    # as "changed" on the next resolve — which re-extracts the artifact and
    # silently discards the slice this script just wrote.
    local = (packages / ARTIFACT_SUBPATH).resolve()
    state_path = packages / "workspace-state.json"
    if not state_path.is_file():
        return local
    import json

    state = json.loads(state_path.read_text())
    artifacts = state.get("object", {}).get("artifacts", [])
    recorded = next((a for a in artifacts if a.get("targetName") == "TDLibFramework"), None)
    if recorded is None:
        return local
    recorded_path = Path(recorded.get("path", ""))
    if recorded_path == local:
        return local
    if local.is_dir():
        # State from another checkout. The artifact here is the one this build
        # tree owns, so point the state back at it rather than patching a
        # directory somebody else's build depends on.
        recorded["path"] = str(local)
        state_path.write_text(json.dumps(state, indent=2))
        print(f"tdlib-maccatalyst: repointed workspace-state at {local}.")
        return local
    return recorded_path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: tdlib-maccatalyst.py <path/to/SourcePackages>", file=sys.stderr)
        return 2
    packages = Path(sys.argv[1])
    xcframework = effective_xcframework(packages)
    info_path = xcframework / "Info.plist"
    if not info_path.is_file():
        print(f"tdlib-maccatalyst: no xcframework at {xcframework} — run a package resolve first.", file=sys.stderr)
        return 1

    info = plistlib.loads(info_path.read_bytes())
    libraries = info.get("AvailableLibraries", [])
    if any(lib.get("LibraryIdentifier") == SLICE_ID for lib in libraries) and (xcframework / SLICE_ID).is_dir():
        print(f"tdlib-maccatalyst: {SLICE_ID} already present.")
        return 0

    source = next((lib for lib in libraries if lib.get("LibraryIdentifier") == SOURCE_ID), None)
    if source is None:
        print(f"tdlib-maccatalyst: no {SOURCE_ID} slice to derive from.", file=sys.stderr)
        return 1

    destination = xcframework / SLICE_ID
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(xcframework / SOURCE_ID, destination, symlinks=True)

    binary = destination / source["BinaryPath"]
    patched = patch_binary(binary)
    if patched == 0:
        print("tdlib-maccatalyst: no macOS build-version load commands found — refusing to register the slice.", file=sys.stderr)
        shutil.rmtree(destination)
        return 1

    entry = dict(source)
    entry["LibraryIdentifier"] = SLICE_ID
    entry["SupportedPlatform"] = "ios"
    entry["SupportedPlatformVariant"] = "maccatalyst"
    libraries.append(entry)
    info["AvailableLibraries"] = libraries
    info_path.write_bytes(plistlib.dumps(info))
    print(f"tdlib-maccatalyst: wrote {SLICE_ID} ({patched} objects retargeted).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
