#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: $0 EXACT_KERNEL_SOURCE NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi

source_dir=$(realpath "$1")
output_dir=$(realpath -m "$2")
defconfig="$source_dir/arch/arm64/configs/exynos8895-dream2lte_defconfig"
selinuxfs="$source_dir/security/selinux/selinuxfs.c"

mkdir "$output_dir"
cp "$defconfig" "$output_dir/original.config"
cp "$defconfig" "$output_dir/.config"
cp "$selinuxfs" "$output_dir/selinuxfs.original.c"
python3 - "$selinuxfs" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_bytes()
override = b"#else\n\n    new_value = 0;\n\tif (new_value != selinux_enforcing) {"
standard = b"#else\n\tif (new_value != selinux_enforcing) {"
if source.count(override) == 1:
    path.write_bytes(source.replace(override, standard))
elif source.count(standard) != 1:
    raise SystemExit("Expected the release kernel's SELinux enforcement override")
PY

"$source_dir/scripts/config" --file "$output_dir/.config" --disable ALWAYS_PERMISSIVE --enable AUDIT
cross_assembler=$(command -v aarch64-linux-gnu-as)
args=(
    -C "$source_dir"
    O="$output_dir"
    ARCH=arm64
    CC="${KERNEL_CC:-clang-14}"
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CLANG_PREFIX="--prefix=${cross_assembler%as}"
    HOSTCC=gcc
    HOSTCFLAGS="-O2 -fcommon"
    LOCALVERSION=-dream2lte-selinux-test
)
export KBUILD_BUILD_USER=rom-builder KBUILD_BUILD_HOST=dream2lte
make "${args[@]}" olddefconfig
grep -qx 'CONFIG_SECURITY_SELINUX=y' "$output_dir/.config"
grep -qx '# CONFIG_ALWAYS_PERMISSIVE is not set' "$output_dir/.config"
grep -qx 'CONFIG_AUDIT=y' "$output_dir/.config"
make -j"${KERNEL_JOBS:-3}" "${args[@]}" Image
sha256sum "$output_dir/arch/arm64/boot/Image" "$output_dir/.config"
