#!/usr/bin/env python3
"""Patch Mali-G71 r16p0-01rel0 Vulkan descriptor limits in libGLES_mali.so."""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ORIG_DIR = ROOT / "build" / "staged_system_orig_p4"
STAGED_DIR = ROOT / "build" / "staged_system_pass3"

OLD_TUPLE = (16, 8, 4, 79)
NEW_TUPLE = (64, 8, 4, 127)

TARGETS = [
    {
        "label": "64-bit",
        "rel": Path("vendor/lib64/egl/libGLES_mali.so"),
        "size": 39443768,
        "sha256": "67f07575f92ea0aedb8522140a7ad08d3be201e3a07eaa5e42a7f7d751d9fac4",
        "offset": 0x1D9D540,
    },
    {
        "label": "32-bit",
        "rel": Path("vendor/lib/egl/libGLES_mali.so"),
        "size": 27303648,
        "sha256": "c3a5a910edbf4a8907f9fd5c3b991274472bb864a6576b53c5f6ad0abbf986af",
        "offset": 0x1160F0,
    },
]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_target(spec: dict) -> None:
    src = ORIG_DIR / spec["rel"]
    dst = STAGED_DIR / spec["rel"]
    if not src.is_file():
        raise FileNotFoundError(f"Missing stock binary: {src}")

    raw = src.read_bytes()
    if len(raw) != spec["size"]:
        raise ValueError(
            f"{spec['label']}: expected size {spec['size']}, got {len(raw)}"
        )

    pre_sha = sha256_bytes(raw)
    if pre_sha != spec["sha256"]:
        raise ValueError(
            f"{spec['label']}: expected SHA-256 {spec['sha256']}, got {pre_sha}"
        )

    off = spec["offset"]
    old_bytes = struct.pack("<4I", *OLD_TUPLE)
    new_bytes = struct.pack("<4I", *NEW_TUPLE)
    found = raw[off : off + 16]
    if found != old_bytes:
        got_tuple = struct.unpack("<4I", found)
        raise ValueError(
            f"{spec['label']}: expected {OLD_TUPLE} at 0x{off:x}, got {got_tuple}"
        )

    patched = bytearray(raw)
    patched[off : off + 16] = new_bytes
    patched_bytes = bytes(patched)

    diffs = [i for i in range(len(raw)) if raw[i] != patched_bytes[i]]
    expected_diffs = [off, off + 12]
    if diffs != expected_diffs:
        raise AssertionError(
            f"{spec['label']}: expected diffs at {[hex(d) for d in expected_diffs]}, "
            f"got {[hex(d) for d in diffs]}"
        )

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(patched_bytes)
    post_sha = sha256_bytes(patched_bytes)

    print(
        f"[{spec['label']}] {spec['rel']}\n"
        f"  offset : 0x{off:x}\n"
        f"  tuple  : {OLD_TUPLE} -> {NEW_TUPLE} ({len(diffs)} bytes changed)\n"
        f"  before : {pre_sha}\n"
        f"  after  : {post_sha}\n"
        f"  output : {dst}"
    )


def main() -> int:
    for spec in TARGETS:
        patch_target(spec)
    return 0


if __name__ == "__main__":
    sys.exit(main())
