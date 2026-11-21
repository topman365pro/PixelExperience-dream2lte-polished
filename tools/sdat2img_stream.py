#!/usr/bin/env python3
"""Convert Android transfer.list + brotli/raw new.dat stream into raw ext4 image."""
import sys
import subprocess


def rangeset(src):
    src_set = src.split(',')
    num_set = [int(item) for item in src_set]
    if len(num_set) != num_set[0] + 1:
        raise ValueError(f"Error parsing data to rangeset: {src}")
    return [(num_set[i], num_set[i + 1]) for i in range(1, len(num_set), 2)]


def parse_transfer_list(path):
    with open(path, 'r') as f:
        version = int(f.readline().strip())
        new_blocks = int(f.readline().strip())
        if version >= 2:
            f.readline()  # stash entries
            f.readline()  # max stash blocks
        commands = []
        max_blk = new_blocks
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(' ')
            cmd = parts[0]
            if cmd in ('erase', 'new', 'zero'):
                r = rangeset(parts[1])
                for _, end in r:
                    if end > max_blk:
                        max_blk = end
                commands.append((cmd, r))
            elif cmd.isdigit():
                continue
            else:
                raise ValueError(f"Unsupported transfer command: {cmd}")
    return version, max_blk, commands


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <transfer_list> <zip_or_new_dat> <out_img> [--from-zip]")
        sys.exit(1)

    transfer_list = sys.argv[1]
    src_path = sys.argv[2]
    out_img = sys.argv[3]
    from_zip = "--from-zip" in sys.argv[4:]

    BLOCK_SIZE = 4096
    version, max_blk, commands = parse_transfer_list(transfer_list)
    print(f"Transfer list v{version}, total blocks={max_blk} ({max_blk * BLOCK_SIZE / (1024**3):.2f} GiB)")

    if from_zip:
        unzip_proc = subprocess.Popen(["unzip", "-p", src_path, "system.new.dat.br"], stdout=subprocess.PIPE)
        brotli_proc = subprocess.Popen(["brotli", "-d", "-c"], stdin=unzip_proc.stdout, stdout=subprocess.PIPE)
        unzip_proc.stdout.close()
        dat_stream = brotli_proc.stdout
    elif src_path.endswith(".br"):
        brotli_proc = subprocess.Popen(["brotli", "-d", "-c", src_path], stdout=subprocess.PIPE)
        dat_stream = brotli_proc.stdout
    else:
        dat_stream = open(src_path, "rb")

    with open(out_img, "wb") as out:
        out.truncate(max_blk * BLOCK_SIZE)
        written_blocks = 0
        for cmd, rset in commands:
            if cmd == "new":
                for begin, end in rset:
                    cnt = end - begin
                    need = cnt * BLOCK_SIZE
                    out.seek(begin * BLOCK_SIZE)
                    rem = need
                    while rem > 0:
                        chunk = dat_stream.read(min(rem, 4 * 1024 * 1024))
                        if not chunk:
                            raise EOFError(f"Unexpected EOF reading new blocks ({rem} bytes left)")
                        out.write(chunk)
                        rem -= len(chunk)
                    written_blocks += cnt
        extra = dat_stream.read(16)
        if extra:
            print(f"Warning: trailing {len(extra)}+ bytes in new.dat stream")
        print(f"Wrote {written_blocks} new blocks cleanly to {out_img}")

    if from_zip:
        rc_b = brotli_proc.wait()
        rc_u = unzip_proc.wait()
        if rc_b != 0 or rc_u != 0:
            raise RuntimeError(f"Stream failed: unzip={rc_u}, brotli={rc_b}")
    elif src_path.endswith(".br"):
        rc_b = brotli_proc.wait()
        if rc_b != 0:
            raise RuntimeError(f"brotli failed: {rc_b}")
    else:
        dat_stream.close()


if __name__ == "__main__":
    main()
