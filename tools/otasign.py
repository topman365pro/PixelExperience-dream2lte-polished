#!/usr/bin/env python3
"""Whole-file Android OTA ZIP signer matching SignApk -w byte-for-byte.

Usage:
  otasign.py <in_zip> <out_zip> <pk8_key> <x509_pem>
  otasign.py --verify <x509_pem> <signed_zip>
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import List, Tuple

CHUNK_SIZE = 1024 * 1024
SIGNAPK_PREFIX = b"signed by SignApk\x00"
SHA1_OID_VALUE = bytes.fromhex("2b0e03021a")


def _parse_der(buf: bytes, off: int = 0) -> Tuple[Tuple[int, bool, bytes, list], int]:
    tag = buf[off]
    i = off + 1
    lb = buf[i]
    i += 1
    if lb & 0x80:
        n = lb & 0x7F
        length = int.from_bytes(buf[i : i + n], "big")
        i += n
    else:
        length = lb
    val = buf[i : i + length]
    end = i + length
    is_cons = bool(tag & 0x20)
    children: List[tuple] = []
    if is_cons:
        p = 0
        while p < len(val):
            ch, p = _parse_der(val, p)
            children.append(ch)
    return (tag, is_cons, val, children), end


def _encode_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def _encode_der(node: Tuple[int, bool, bytes, list]) -> bytes:
    tag, is_cons, val, children = node
    body = b"".join(_encode_der(c) for c in children) if is_cons else val
    return bytes([tag]) + _encode_len(len(body)) + body


def _add_sha1_null(node: Tuple[int, bool, bytes, list]) -> Tuple[int, bool, bytes, list]:
    """Insert ASN.1 NULL into bare SHA-1 AlgorithmIdentifiers (BouncyCastle/SignApk style)."""
    tag, is_cons, val, children = node
    if is_cons:
        children = [_add_sha1_null(c) for c in children]
        if (
            tag == 0x30
            and len(children) == 1
            and children[0][0] == 0x06
            and not children[0][1]
            and children[0][2] == SHA1_OID_VALUE
        ):
            children.append((0x05, False, b"", []))
    return (tag, is_cons, val, children)


def find_eocd(path: str) -> Tuple[int, int, int]:
    """Return (file_size, eocd_abs, comment_len) after validating EOCD."""
    file_size = os.path.getsize(path)
    read_len = min(file_size, 65536 + 22)
    with open(path, "rb") as f:
        f.seek(file_size - read_len)
        tail = f.read(read_len)
    idx = tail.rfind(b"PK\x05\x06")
    if idx < 0 or len(tail) - idx < 22:
        raise ValueError("ZIP End-of-Central-Directory (PK\\x05\\x06) not found")
    eocd_abs = file_size - read_len + idx
    comment_len = struct.unpack("<H", tail[idx + 20 : idx + 22])[0]
    if eocd_abs + 22 + comment_len != file_size:
        raise ValueError(
            f"Invalid EOCD comment_len={comment_len} at {eocd_abs} for size {file_size}"
        )
    return file_size, eocd_abs, comment_len


def _stream_prefix(path: str, nbytes: int, sink) -> None:
    remaining = nbytes
    with open(path, "rb") as fin:
        while remaining > 0:
            chunk = fin.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise EOFError("Unexpected EOF while streaming ZIP prefix")
            sink.write(chunk)
            remaining -= len(chunk)


def compute_cms_der(path: str, signed_len: int, pk8: str, x509_pem: str) -> bytes:
    """Compute detached PKCS#7/CMS DER matching SignApk -w over path[:signed_len]."""
    proc = subprocess.Popen(
        [
            "openssl",
            "cms",
            "-sign",
            "-binary",
            "-in",
            "-",
            "-signer",
            x509_pem,
            "-inkey",
            pk8,
            "-noattr",
            "-md",
            "sha1",
            "-outform",
            "DER",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
    _stream_prefix(path, signed_len, proc.stdin)
    proc.stdin.close()
    raw_sig = proc.stdout.read()
    err = proc.stderr.read().decode("utf-8", errors="replace")
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"openssl cms -sign failed ({rc}): {err}")

    tree, end = _parse_der(raw_sig)
    if end != len(raw_sig):
        raise RuntimeError(f"Trailing bytes in OpenSSL CMS output: {end} != {len(raw_sig)}")
    return _encode_der(_add_sha1_null(tree))


def build_trailer(sig_der: bytes) -> Tuple[int, bytes]:
    """Return (comment_len, comment_bytes_without_2byte_len) for SignApk whole-file trailer."""
    body_len = len(SIGNAPK_PREFIX) + len(sig_der)
    total_size = body_len + 6
    if total_size > 0xFFFF:
        raise ValueError(f"Signature comment too big: {total_size}")
    signature_start = total_size - len(SIGNAPK_PREFIX)
    footer = struct.pack("<HHH", signature_start, 0xFFFF, total_size)
    comment_bytes = SIGNAPK_PREFIX + sig_der + footer
    if len(comment_bytes) != total_size:
        raise AssertionError("Trailer size mismatch")
    if b"PK\x05\x06" in comment_bytes:
        raise RuntimeError("Found spurious EOCD marker inside signature comment")
    return total_size, comment_bytes


def sign_zip(in_zip: str, out_zip: str, pk8: str, x509_pem: str) -> None:
    file_size, eocd_abs, comment_len = find_eocd(in_zip)
    if comment_len != 0 or eocd_abs + 22 != file_size:
        raise ValueError(
            f"Input ZIP already has a comment (comment_len={comment_len}); pass unsigned ZIP"
        )
    signed_len = eocd_abs + 20
    sig_der = compute_cms_der(in_zip, signed_len, pk8, x509_pem)
    total_size, comment_bytes = build_trailer(sig_der)

    tmp_out = f"{out_zip}.tmp"
    with open(in_zip, "rb") as fin, open(tmp_out, "wb") as fout:
        remaining = signed_len
        while remaining > 0:
            buf = fin.read(min(CHUNK_SIZE, remaining))
            if not buf:
                raise EOFError("Unexpected EOF copying ZIP payload")
            fout.write(buf)
            remaining -= len(buf)
        fout.write(struct.pack("<H", total_size))
        fout.write(comment_bytes)
    os.replace(tmp_out, out_zip)
    print(
        f"otasign: signed {os.path.basename(out_zip)} "
        f"(size={os.path.getsize(out_zip)}, sig_der={len(sig_der)}B, comment={total_size}B)"
    )


def verify_zip(ca_pem: str, signed_zip: str) -> None:
    file_size, eocd_abs, comment_len = find_eocd(signed_zip)
    if comment_len < len(SIGNAPK_PREFIX) + 6:
        raise ValueError(f"ZIP comment too short ({comment_len}B) to contain SignApk trailer")

    with open(signed_zip, "rb") as f:
        f.seek(eocd_abs + 22)
        comment = f.read(comment_len)

    if not comment.startswith(SIGNAPK_PREFIX):
        raise ValueError("Missing 'signed by SignApk\\x00' header in ZIP comment")

    sig_start, magic, total_size = struct.unpack("<HHH", comment[-6:])
    if magic != 0xFFFF or total_size != comment_len:
        raise ValueError(
            f"Invalid SignApk footer: sig_start={sig_start}, magic=0x{magic:04x}, total_size={total_size}"
        )
    expected_sig_len = comment_len - len(SIGNAPK_PREFIX) - 6
    if sig_start != expected_sig_len + 6:
        raise ValueError(
            f"Footer sig_start mismatch: {sig_start} != {expected_sig_len + 6}"
        )

    sig_der = comment[len(SIGNAPK_PREFIX) : -6]
    with tempfile.NamedTemporaryFile(suffix=".p7s", delete=False) as tf:
        tf.write(sig_der)
        sig_path = tf.name

    try:
        proc = subprocess.Popen(
            [
                "openssl",
                "cms",
                "-verify",
                "-binary",
                "-inform",
                "DER",
                "-in",
                sig_path,
                "-content",
                "/dev/stdin",
                "-CAfile",
                ca_pem,
                "-out",
                "/dev/null",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert proc.stdin is not None and proc.stderr is not None
        _stream_prefix(signed_zip, eocd_abs + 20, proc.stdin)
        proc.stdin.close()
        err = proc.stderr.read().decode("utf-8", errors="replace").strip()
        rc = proc.wait()
        if rc != 0:
            raise RuntimeError(f"CMS verification failed ({rc}): {err}")
        print(f"otasign verify OK: {signed_zip} ({err})")
    finally:
        if os.path.exists(sig_path):
            os.remove(sig_path)


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--verify":
        verify_zip(sys.argv[2], sys.argv[3])
        return 0
    if len(sys.argv) == 5:
        sign_zip(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
        return 0
    print(
        f"Usage:\n  {sys.argv[0]} <in_zip> <out_zip> <pk8> <x509_pem>\n"
        f"  {sys.argv[0]} --verify <x509_pem> <signed_zip>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
