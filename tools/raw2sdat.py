#!/usr/bin/env python3
"""Convert a raw ext4 filesystem image to Android v4 sdat (.transfer.list + .new.dat).

Uses dumpe2fs free-block bitmaps so only genuinely unallocated all-zero blocks
become `erase` (BLKDISCARD) while allocated/metadata all-zero blocks stay `zero`.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from typing import Iterable, List, Tuple

BLOCK_SIZE = 4096
MAX_BLOCKS_PER_TRANSFER = 1024
DUMPE2FS = "/opt/homebrew/opt/e2fsprogs/sbin/dumpe2fs"


def parse_free_blocks(raw_img: str, total_blocks: int) -> Tuple[bytearray, int]:
    """Return a bytearray mask (1 = free block in ext4) and expected free count."""
    dumpe2fs_bin = DUMPE2FS if os.path.exists(DUMPE2FS) else "dumpe2fs"
    proc = subprocess.run(
        [dumpe2fs_bin, raw_img],
        capture_output=True,
        text=True,
        check=True,
    )

    expected_free = None
    free_mask = bytearray(total_blocks)
    free_count = 0

    for line in proc.stdout.splitlines():
        if expected_free is None:
            m = re.match(r"^Free blocks:\s+(\d+)\s*$", line)
            if m:
                expected_free = int(m.group(1))
                continue
        if line.startswith("  Free blocks:"):
            rest = line.split(":", 1)[1].strip()
            if not rest:
                continue
            for item in rest.split(","):
                item = item.strip()
                if not item:
                    continue
                if "-" in item:
                    a_str, b_str = item.split("-", 1)
                    a, b = int(a_str), int(b_str)
                    if not (0 <= a <= b < total_blocks):
                        raise ValueError(f"Out-of-range free block interval {a}-{b}")
                    free_mask[a : b + 1] = b"\x01" * (b - a + 1)
                    free_count += b - a + 1
                else:
                    idx = int(item)
                    if not (0 <= idx < total_blocks):
                        raise ValueError(f"Out-of-range free block {idx}")
                    free_mask[idx] = 1
                    free_count += 1

    if expected_free is None:
        raise RuntimeError("Could not find 'Free blocks:' in dumpe2fs header")
    if free_count != expected_free:
        raise RuntimeError(
            f"Parsed free block count {free_count} != superblock Free blocks {expected_free}"
        )
    return free_mask, free_count


def format_rangeset(ranges: Iterable[Tuple[int, int]]) -> str:
    flat: List[str] = []
    for s, e in ranges:
        flat.append(str(s))
        flat.append(str(e))
    return f"{len(flat)}," + ",".join(flat)


def split_write_transfers(
    out_lines: List[str], op: str, ranges: List[Tuple[int, int]]
) -> int:
    """Split contiguous ranges into recovery-safe chunks <= 1024 blocks."""
    total = 0
    batch: List[Tuple[int, int]] = []
    batch_blocks = 0

    for s, e in ranges:
        cur = s
        while cur < e:
            room = MAX_BLOCKS_PER_TRANSFER - batch_blocks
            take = min(e - cur, room)
            batch.append((cur, cur + take))
            batch_blocks += take
            total += take
            cur += take
            if batch_blocks == MAX_BLOCKS_PER_TRANSFER:
                out_lines.append(f"{op} {format_rangeset(batch)}\n")
                batch = []
                batch_blocks = 0

    if batch:
        out_lines.append(f"{op} {format_rangeset(batch)}\n")
    return total


def convert(raw_img: str, out_transfer_list: str, out_new_dat: str) -> None:
    file_size = os.path.getsize(raw_img)
    if file_size % BLOCK_SIZE != 0:
        raise ValueError(f"Image size {file_size} is not a multiple of {BLOCK_SIZE}")
    total_blocks = file_size // BLOCK_SIZE

    free_mask, _ = parse_free_blocks(raw_img, total_blocks)
    zero_block = b"\x00" * BLOCK_SIZE

    new_ranges: List[Tuple[int, int]] = []
    zero_ranges: List[Tuple[int, int]] = []
    erase_ranges: List[Tuple[int, int]] = []

    cur_kind = -1  # 0=zero, 1=new, 2=erase
    cur_start = 0
    new_blocks_written = 0

    def flush_run(kind: int, start: int, end: int) -> None:
        if end <= start:
            return
        if kind == 1:
            new_ranges.append((start, end))
        elif kind == 0:
            zero_ranges.append((start, end))
        elif kind == 2:
            erase_ranges.append((start, end))

    # Stream in 1024-block (4 MiB) chunks to avoid large RAM spikes
    chunk_blocks = 1024
    with open(raw_img, "rb") as fin, open(out_new_dat, "wb") as fdat:
        blk = 0
        while blk < total_blocks:
            n = min(chunk_blocks, total_blocks - blk)
            buf = fin.read(n * BLOCK_SIZE)
            if len(buf) != n * BLOCK_SIZE:
                raise EOFError("Unexpected short read from raw image")
            mv = memoryview(buf)
            for i in range(n):
                b = blk + i
                slice_bytes = mv[i * BLOCK_SIZE : (i + 1) * BLOCK_SIZE]
                if slice_bytes != zero_block:
                    kind = 1
                    fdat.write(slice_bytes)
                    new_blocks_written += 1
                elif free_mask[b]:
                    kind = 2
                else:
                    kind = 0

                if kind != cur_kind:
                    flush_run(cur_kind, cur_start, b)
                    cur_kind = kind
                    cur_start = b
            blk += n
        flush_run(cur_kind, cur_start, total_blocks)

    out_lines: List[str] = []
    if erase_ranges:
        out_lines.append(f"erase {format_rangeset(erase_ranges)}\n")
    new_total = split_write_transfers(out_lines, "new", new_ranges)
    zero_total = split_write_transfers(out_lines, "zero", zero_ranges)
    erase_total = sum(e - s for s, e in erase_ranges)

    if new_total != new_blocks_written:
        raise AssertionError(
            f"new_total {new_total} != new_blocks_written {new_blocks_written}"
        )
    if new_total + zero_total + erase_total != total_blocks:
        raise AssertionError("Block accounting mismatch")
    if os.path.getsize(out_new_dat) != new_blocks_written * BLOCK_SIZE:
        raise AssertionError("Output new.dat size mismatch")

    written_total = new_total + zero_total
    with open(out_transfer_list, "w", encoding="utf-8") as ftl:
        ftl.write("4\n")
        ftl.write(f"{written_total}\n")
        ftl.write("0\n")
        ftl.write("0\n")
        ftl.writelines(out_lines)

    print(
        f"raw2sdat: blocks={total_blocks} new={new_total} zero={zero_total} "
        f"erase={erase_total} new.dat={os.path.getsize(out_new_dat)} bytes"
    )


def main() -> int:
    if len(sys.argv) != 4:
        print(
            f"Usage: {sys.argv[0]} <raw_img> <out_transfer_list> <out_new_dat>",
            file=sys.stderr,
        )
        return 2
    convert(sys.argv[1], sys.argv[2], sys.argv[3])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
