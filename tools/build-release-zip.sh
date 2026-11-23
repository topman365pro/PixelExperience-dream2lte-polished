#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
STAGED="$BUILD/staged_system_pass3"
RELEASE="$ROOT/release"
TOOLS="$ROOT/tools"

STOCK_IMG="$BUILD/system.img"
POLISHED_IMG="$BUILD/system-polished.img"
BOOT_IMG="$BUILD/boot-dream2lte-pass3.img"
OUT_ZIP="$RELEASE/PixelExperience_Plus_dream2lte-13.0-20261123-POLISHED.zip"

DEBUGFS="/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
E2FSCK="/opt/homebrew/opt/e2fsprogs/sbin/e2fsck"

if ! command -v brotli >/dev/null 2>&1; then
  echo "ERROR: brotli not found in PATH" >&2
  exit 1
fi
for bin in "$DEBUGFS" "$E2FSCK"; do
  if [ ! -x "$bin" ]; then
    echo "ERROR: missing required e2fsprogs binary: $bin" >&2
    exit 1
  fi
done

avail_kb=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
avail_gib=$(awk "BEGIN {printf \"%.2f\", $avail_kb / 1048576}")
echo "[1/9] Free disk space: ${avail_gib} GiB (${avail_kb} KiB)"
if [ "$avail_kb" -lt $((8 * 1048576)) ]; then
  echo "ERROR: Need at least 8 GiB free disk space, have ${avail_gib} GiB" >&2
  exit 1
fi

for req in \
  "$STOCK_IMG" \
  "$BOOT_IMG" \
  "$STAGED/framework/framework.jar" \
  "$STAGED/vendor/etc/selinux/precompiled_sepolicy" \
  "$BUILD/META-INF/com/android/metadata" \
  "$BUILD/META-INF/com/android/metadata.pb" \
  "$BUILD/META-INF/com/android/otacert" \
  "$BUILD/META-INF/com/google/android/update-binary" \
  "$BUILD/release_meta/META-INF/com/google/android/updater-script" \
  "$RELEASE/CHANGELOG.md" \
  "$TOOLS/raw2sdat.py" \
  "$TOOLS/sdat2img_stream.py" \
  "$TOOLS/otasign.py" \
  "$TOOLS/releasetools/testkey.pk8" \
  "$TOOLS/releasetools/testkey.x509.pem"
do
  if [ ! -e "$req" ]; then
    echo "ERROR: Missing required input: $req" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "$BUILD/release_work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "[2/9] Copying stock system.img -> system-polished.img..."
cp "$STOCK_IMG" "$POLISHED_IMG"

echo "[3/9] Generating debugfs patch manifest and injecting Pass 1 + Pass 2 + Pass 3 files..."
python3 - "$STAGED" "$POLISHED_IMG" "$WORK" "$DEBUGFS" << 'PYEOF'
import os
import subprocess
import sys

staged, img, work, debugfs = sys.argv[1:5]

entries = []
# /sepolicy mirrors precompiled_sepolicy
entries.append((
    os.path.join(staged, "vendor/etc/selinux/precompiled_sepolicy"),
    "/sepolicy",
    "0100644",
    0,
    0,
    "u:object_r:sepolicy_file:s0",
))

for dirpath, _, filenames in os.walk(staged):
    for fn in sorted(filenames):
        src = os.path.join(dirpath, fn)
        rel = os.path.relpath(src, staged).replace(os.sep, "/")
        ext4_path = f"/system/{rel}"
        if rel == "build.prop":
            mode, label = "0100600", "u:object_r:system_file:s0"
        elif rel == "vendor/build.prop":
            mode, label = "0100600", "u:object_r:vendor_file:s0"
        elif rel.startswith("vendor/lib64/egl/") or rel.startswith("vendor/lib/egl/"):
            mode, label = "0100644", "u:object_r:same_process_hal_file:s0"
        elif rel.startswith("vendor/etc/"):
            mode, label = "0100644", "u:object_r:vendor_configs_file:s0"
        else:
            mode, label = "0100644", "u:object_r:system_file:s0"
        entries.append((src, ext4_path, mode, 0, 0, label))

entries.sort(key=lambda x: x[1])

# Verify every target path currently exists in stock image so rm succeeds cleanly
check_cmds = "".join(f"stat {p}\n" for _, p, _, _, _, _ in entries)
chk = subprocess.run([debugfs, img], input=check_cmds, text=True, capture_output=True)
if "File not found" in chk.stderr or "File not found" in chk.stdout:
    raise RuntimeError(f"Some target path was missing in base system.img:\n{chk.stderr}")

write_cmds = []
for src, ext4_path, mode, uid, gid, label in entries:
    write_cmds.append(f"rm {ext4_path}")
    write_cmds.append(f'write "{src}" {ext4_path}')
    write_cmds.append(f"set_inode_field {ext4_path} uid {uid}")
    write_cmds.append(f"set_inode_field {ext4_path} gid {gid}")
    write_cmds.append(f"set_inode_field {ext4_path} mode {mode}")
    write_cmds.append(f'ea_set {ext4_path} security.selinux "{label}\\000"')

# Preserve stock binary for audio HAL, only relabel to hal_audio_default_exec
audio_hal = "/system/vendor/bin/hw/android.hardware.audio.service.universal8895"
write_cmds.append(f'ea_set {audio_hal} security.selinux "u:object_r:hal_audio_default_exec:s0\\000"')

cmd_file = os.path.join(work, "debugfs_patch.cmds")
with open(cmd_file, "w") as f:
    f.write("\n".join(write_cmds) + "\n")

res = subprocess.run([debugfs, "-w", "-f", cmd_file, img], capture_output=True, text=True)
if res.returncode != 0:
    raise RuntimeError(f"debugfs failed ({res.returncode}):\n{res.stderr}")
for err_tok in ("File not found", "File exists", "Ext2fs", "No space", "Illegal", "Usage:"):
    if err_tok in res.stderr or err_tok in res.stdout:
        raise RuntimeError(f"debugfs reported '{err_tok}':\nSTDOUT:{res.stdout}\nSTDERR:{res.stderr}")

# Save expected manifest for read-back verification
manifest = os.path.join(work, "manifest.tsv")
with open(manifest, "w") as mf:
    for src, ext4_path, mode, uid, gid, label in entries:
        mf.write(f"{src}\t{ext4_path}\t{mode[-3:]}\t{uid}\t{gid}\t{label}\n")
    mf.write(f"__KEEP__\t{audio_hal}\t755\t0\t2000\tu:object_r:hal_audio_default_exec:s0\n")

print(f"Patched {len(entries)} files + audio HAL xattr via debugfs.")
PYEOF

echo "[4/9] Running e2fsck -fn on system-polished.img..."
"$E2FSCK" -fn "$POLISHED_IMG"

echo "[5/9] Read-back verifying SHA-256, mode, uid, gid, and security.selinux inside system-polished.img..."
python3 - "$POLISHED_IMG" "$WORK" "$DEBUGFS" << 'PYEOF'
import hashlib
import os
import re
import subprocess
import sys

img, work, debugfs = sys.argv[1:4]
manifest = os.path.join(work, "manifest.tsv")
dump_dir = os.path.join(work, "dump")
os.makedirs(dump_dir, exist_ok=True)

rows = []
with open(manifest) as mf:
    for line in mf:
        rows.append(line.rstrip("\n").split("\t"))

verify_cmds = []
for idx, (src, ext4_path, exp_mode, exp_uid, exp_gid, exp_label) in enumerate(rows):
    verify_cmds.append(f"stat {ext4_path}")
    verify_cmds.append(f"ea_get {ext4_path} security.selinux")
    if src != "__KEEP__":
        dump_out = os.path.join(dump_dir, f"f_{idx}")
        verify_cmds.append(f'dump {ext4_path} "{dump_out}"')

vfile = os.path.join(work, "verify.cmds")
with open(vfile, "w") as f:
    f.write("\n".join(verify_cmds) + "\n")

res = subprocess.run([debugfs, "-f", vfile, img], capture_output=True, text=True)
if res.returncode != 0:
    raise RuntimeError(f"debugfs verify failed: {res.stderr}")
for err_tok in ("File not found", "Usage:", "Ext2fs"):
    if err_tok in res.stderr or err_tok in res.stdout:
        raise RuntimeError(f"debugfs verify reported '{err_tok}':\n{res.stderr}\n{res.stdout}")

# Verify each entry individually cleanly using targeted blocks or per-file parse
# Parse stat + ea_get sequentially
text = res.stdout
blocks = text.split("Inode: ")[1:]
if len(blocks) != len(rows):
    raise RuntimeError(f"Expected {len(rows)} stat blocks, got {len(blocks)}")

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while True:
            b = f.read(1048576)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

for idx, ((src, ext4_path, exp_mode, exp_uid, exp_gid, exp_label), blk) in enumerate(zip(rows, blocks)):
    m_mode = re.search(r"Mode:\s+0(\d{3})", blk)
    m_user = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)", blk)
    m_ea = re.search(r'security\.selinux \(\d+\) = "([^"]+)\\000"', blk)
    if not (m_mode and m_user and m_ea):
        raise RuntimeError(f"Failed to parse metadata for {ext4_path}:\n{blk}")
    got_mode = m_mode.group(1)
    got_uid, got_gid = m_user.group(1), m_user.group(2)
    got_label = m_ea.group(1)
    if got_mode != exp_mode or got_uid != exp_uid or got_gid != exp_gid or got_label != exp_label:
        raise AssertionError(
            f"Metadata mismatch on {ext4_path}: "
            f"got mode={got_mode} {got_uid}:{got_gid} {got_label}, "
            f"expected mode={exp_mode} {exp_uid}:{exp_gid} {exp_label}"
        )
    if src != "__KEEP__":
        dump_out = os.path.join(dump_dir, f"f_{idx}")
        if sha256(src) != sha256(dump_out):
            raise AssertionError(f"SHA-256 content mismatch after dump on {ext4_path}")
        os.remove(dump_out)

print(f"Read-back verified ALL {len(rows)} entries (SHA-256, mode, uid/gid, security.selinux).")
PYEOF

echo "[6/9] Converting system-polished.img -> sdat + brotli (-q 6)..."
python3 "$TOOLS/raw2sdat.py" "$POLISHED_IMG" "$WORK/system.transfer.list" "$WORK/system.new.dat"
brotli -q 6 -f "$WORK/system.new.dat" -o "$WORK/system.new.dat.br"
rm -f "$WORK/system.new.dat"
: > "$WORK/system.patch.dat"

echo "[7/9] Round-trip verifying sdat2img_stream.py -> e2fsck -fn -> byte-for-byte SHA-256 match..."
python3 "$TOOLS/sdat2img_stream.py" "$WORK/system.transfer.list" "$WORK/system.new.dat.br" "$WORK/system-roundtrip.img"
"$E2FSCK" -fn "$WORK/system-roundtrip.img"
sha_orig=$(shasum -a 256 "$POLISHED_IMG" | awk '{print $1}')
sha_rt=$(shasum -a 256 "$WORK/system-roundtrip.img" | awk '{print $1}')
echo "  system-polished.img : $sha_orig"
echo "  system-roundtrip.img: $sha_rt"
if [ "$sha_orig" != "$sha_rt" ]; then
  echo "ERROR: Round-trip sdat image SHA-256 mismatch!" >&2
  exit 1
fi
rm -f "$WORK/system-roundtrip.img"

avail_after_rt=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
if [ "$avail_after_rt" -lt $((10 * 1048576)) ]; then
  echo "  Free disk < 10 GiB; pruning reproducible intermediate system-polished.img..."
  rm -f "$POLISHED_IMG"
fi

echo "[8/9] Packing unsigned OTA ZIP and signing with otasign.py..."
UNSIGNED_ZIP="$WORK/unsigned.zip"
python3 - "$UNSIGNED_ZIP" "$BUILD" "$BOOT_IMG" "$WORK" "$RELEASE/CHANGELOG.md" << 'PYEOF'
import os
import sys
import zipfile

out_zip, build_dir, boot_img, work_dir, changelog = sys.argv[1:6]
TS = (2009, 1, 1, 0, 0, 0)

def add_file(zf, src_path, arcname, compress_type):
    zi = zipfile.ZipInfo(arcname, date_time=TS)
    zi.compress_type = compress_type
    zi.create_system = 3  # Unix
    perm = 0o755 if arcname.endswith("update-binary") else 0o644
    zi.external_attr = (0o100000 | perm) << 16
    with open(src_path, "rb") as f:
        # Read sequentially cleanly using open() handle? ZipFile.writestr loads bytes into RAM.
        # For system.new.dat.br (~1.4 GiB) we use write/open(zi, 'w') streaming!
        with zf.open(zi, "w") as dst:
            while True:
                chunk = f.read(1048576)
                if not chunk:
                    break
                dst.write(chunk)

with zipfile.ZipFile(out_zip, "w", allowZip64=False) as zf:
    add_file(zf, os.path.join(build_dir, "META-INF/com/android/metadata"), "META-INF/com/android/metadata", zipfile.ZIP_DEFLATED)
    add_file(zf, os.path.join(build_dir, "META-INF/com/android/metadata.pb"), "META-INF/com/android/metadata.pb", zipfile.ZIP_DEFLATED)
    add_file(zf, os.path.join(work_dir, "system.new.dat.br"), "system.new.dat.br", zipfile.ZIP_STORED)
    add_file(zf, os.path.join(work_dir, "system.patch.dat"), "system.patch.dat", zipfile.ZIP_STORED)
    add_file(zf, os.path.join(build_dir, "META-INF/com/google/android/update-binary"), "META-INF/com/google/android/update-binary", zipfile.ZIP_DEFLATED)
    add_file(zf, os.path.join(build_dir, "release_meta/META-INF/com/google/android/updater-script"), "META-INF/com/google/android/updater-script", zipfile.ZIP_DEFLATED)
    add_file(zf, boot_img, "boot.img", zipfile.ZIP_DEFLATED)
    add_file(zf, os.path.join(work_dir, "system.transfer.list"), "system.transfer.list", zipfile.ZIP_DEFLATED)
    add_file(zf, os.path.join(build_dir, "META-INF/com/android/otacert"), "META-INF/com/android/otacert", zipfile.ZIP_DEFLATED)
    add_file(zf, changelog, "CHANGELOG.md", zipfile.ZIP_DEFLATED)
PYEOF

mkdir -p "$RELEASE"
python3 "$TOOLS/otasign.py" "$UNSIGNED_ZIP" "$OUT_ZIP" \
  "$TOOLS/releasetools/testkey.pk8" "$TOOLS/releasetools/testkey.x509.pem"
rm -f "$UNSIGNED_ZIP"

echo "[9/9] Verifying signed ZIP integrity, CMS signature, and writing SHA256SUMS.txt..."
unzip -t "$OUT_ZIP"
python3 "$TOOLS/otasign.py" --verify "$BUILD/META-INF/com/android/otacert" "$OUT_ZIP"
(
  cd "$RELEASE"
  shasum -a 256 "$(basename "$OUT_ZIP")" "CHANGELOG.md" > "SHA256SUMS.txt"
)
rm -f "$POLISHED_IMG"
ls -lh "$OUT_ZIP" "$RELEASE/SHA256SUMS.txt"
cat "$RELEASE/SHA256SUMS.txt"
df -h "$ROOT"
