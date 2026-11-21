#!/usr/bin/env python3
"""Replace the kernel in the legacy dream2lte Android boot image."""

import argparse
import hashlib
import struct
from pathlib import Path


HEADER_ID = 576
PAGE_SIZE = 2048
BOOT_PARTITION_SIZE = 40 * 1024 * 1024
TRAILER = b"SEANDROIDENFORCE"


def align(size):
    return (size + PAGE_SIZE - 1) // PAGE_SIZE * PAGE_SIZE


def image_id(parts):
    digest = hashlib.sha1()
    for part in parts:
        digest.update(part)
        digest.update(struct.pack("<I", len(part)))
    return digest.digest()


def unpack(template):
    if len(template) < PAGE_SIZE or template[:8] != b"ANDROID!":
        raise ValueError("Missing Android boot image header")
    kernel_size, _, ramdisk_size, _, second_size, _, _, page_size, dt_size = (
        struct.unpack_from("<9I", template, 8)
    )
    if page_size != PAGE_SIZE or second_size != 0 or dt_size == 0:
        raise ValueError("Expected the dream2lte legacy boot image layout")

    parts = []
    offset = PAGE_SIZE
    for size in (kernel_size, ramdisk_size, second_size, dt_size):
        parts.append(template[offset : offset + size])
        offset += align(size)

    if template[offset:] != TRAILER:
        raise ValueError("Unexpected bytes after the boot image payload")
    if template[HEADER_ID : HEADER_ID + 20] != image_id(parts):
        raise ValueError("Boot image ID does not match the payload")
    return bytearray(template[:PAGE_SIZE]), parts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path)
    parser.add_argument("kernel", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    header, parts = unpack(args.template.read_bytes())
    kernel = args.kernel.read_bytes()
    if kernel[56:60] != b"ARM\x64":
        raise ValueError("Expected a raw ARM64 Linux Image")
    parts[0] = kernel
    struct.pack_into("<I", header, 8, len(kernel))
    header[HEADER_ID : HEADER_ID + 20] = image_id(parts)

    padded = [part.ljust(align(len(part)), b"\x00") for part in parts]
    image = b"".join([header, *padded, TRAILER])
    if len(image) > BOOT_PARTITION_SIZE:
        raise ValueError("Boot image exceeds the SM-G955F boot partition")
    unpack(image)
    with args.output.open("xb") as output:
        output.write(image)
    print(f"{hashlib.sha256(image).hexdigest()}  {args.output}")


if __name__ == "__main__":
    main()
