#!/usr/bin/env bash
# Regenerate patches/0031 from drivers/aw8697.c.
#
# Same layout as the tfa987x one: the .c file is the truth, the patch bundles
# a new file plus the Kconfig and Makefile entries.
#
# Where the driver came from: mainline has aw86927.c (AW86927, another
# generation, different register map) but not AW8697. There is an upstream
# series "[PATCH 2/2] Input: aw8697 - Add Awinic AW8697 haptics driver"
# (Armandas Kvietkus, 2026-09-30, tested on the POCO F3 -- same family as this
# phone). It is not in 7.2.8, so it is carried here as a patch. The driver is
# self-contained: it calibrates the LRA at probe and reads no device tree
# properties beyond reg/IRQ/reset.
#
# Usage: scripts/regen-op8p-aw8697-patch.sh [--check]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="${ROOT}/external-and-mods/kernel-sm8250"
SRC_C="${MOD}/drivers/aw8697.c"
PATCH="${MOD}/patches/0031-Input-aw8697-add-the-Awinic-AW8697-haptics-driver.patch"
KVER=7.2.8
TARBALL="${KSRC_TARBALL:-${ROOT}/work/cache/linux-${KVER}.tar.xz}"

REL=drivers/input/misc
C_NAME=aw8697.c
KCONF=INPUT_AW8697

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

die() { echo "regen-op8p-aw8697: $*" >&2; exit 1; }
[[ -f "$SRC_C" ]] || die "no driver source at $SRC_C"
[[ -f "$TARBALL" ]] || die "no kernel tarball at $TARBALL"

work="${ROOT}/work/regen-aw8697"
rm -rf "$work" 2>/dev/null || true
mkdir -p "$work/a/$REL" "$work/b/$REL"

untar_one() {
  local rel="$1" dest="$2" t
  for t in tar /c/Windows/System32/tar.exe; do
    command -v "$t" >/dev/null 2>&1 || [[ -x "$t" ]] || continue
    if "$t" -xJf "$TARBALL" -C "$dest" --strip-components=4 "$rel" 2>/dev/null \
       && [[ -f "$dest/$(basename "$rel")" ]]; then
      return 0
    fi
  done
  return 1
}

for f in Kconfig Makefile; do
  untar_one "linux-${KVER}/${REL}/${f}" "$work/a/$REL" || die "cannot extract $f"
  cp "$work/a/$REL/$f" "$work/b/$REL/$f"
done

# Kconfig: right before INPUT_AW86927, so the two Awinic entries stay
# together and in alphabetical order.
awk '
  /^config INPUT_AW86927$/ && !done {
    print "config INPUT_AW8697"
    print "\ttristate \"Awinic AW8697 Haptic Driver Support\""
    print "\tdepends on I2C && INPUT"
    print "\tselect INPUT_FF_MEMLESS"
    print "\tselect REGMAP_I2C"
    print "\thelp"
    print "\t  Say Y here if you have an Awinic AW8697 haptic chip. The"
    print "\t  AW8697 drives a linear resonant actuator and calibrates its"
    print "\t  resonance at probe; it exposes a force feedback device with"
    print "\t  rumble support. Found in the OnePlus 8 Pro and the Xiaomi"
    print "\t  POCO F3."
    print ""
    done = 1
  }
  { print }
' "$work/a/$REL/Kconfig" >"$work/b/$REL/Kconfig"
grep -q "config $KCONF" "$work/b/$REL/Kconfig" || die "Kconfig anchor missed"

awk '
  /^obj-\$\(CONFIG_INPUT_AW86927\)/ && !d1 {
    print "obj-$(CONFIG_INPUT_AW8697)\t\t+= aw8697.o"
    d1 = 1
  }
  { print }
' "$work/a/$REL/Makefile" >"$work/b/$REL/Makefile"
[[ "$(grep -c 'aw8697\.o' "$work/b/$REL/Makefile")" == 1 ]] || die "Makefile anchor missed"

cp "$SRC_C" "$work/b/$REL/$C_NAME"

( cd "$work" && diff -Naur a b >raw.patch || true )
[[ -s "$work/raw.patch" ]] || die "diff produced nothing"

header=""
if [[ -f "$PATCH" ]] && grep -qx -- '---' "$PATCH"; then
  header="$(awk '/^---$/{exit} {print}' "$PATCH")"
  [[ "$header" == ---\ a/* ]] && header=""
fi
sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*$/\1 \2/; /^diff -Naur /d' \
  "$work/raw.patch" >"$work/clean.patch"
if [[ -n "$header" ]]; then
  { printf '%s\n---\n' "$header"; cat "$work/clean.patch"; } >"$work/new.patch"
else
  cp "$work/clean.patch" "$work/new.patch"
fi

if [[ $CHECK == 0 ]]; then
  if cmp -s "$work/new.patch" "$PATCH" 2>/dev/null; then
    echo "regen-op8p-aw8697: patch already up to date"
  else
    cp "$work/new.patch" "$PATCH"
    echo "regen-op8p-aw8697: wrote $PATCH"
  fi
fi

dec=$(awk -v f="+++ b/$REL/$C_NAME" '
  $0 == f { on = 1; next }
  on && /^\+\+\+ / { on = 0 }
  on && match($0, /\+1,[0-9]+/) { d = substr($0, RSTART + 3, RLENGTH - 3) + 0 }
  on && /^\+/ { c++ }
  END { printf "%d %d\n", d + 0, c + 0 }' "$PATCH")
set -- $dec
[[ "$1" -gt 0 && "$1" == "$2" ]] || die "new-file hunk says $1 lines, patch has $2"
grep -q "^+++ b/$REL/Kconfig\$" "$PATCH" || die "no Kconfig hunk"
grep -q "^+++ b/$REL/Makefile\$" "$PATCH" || die "no Makefile hunk"
grep -q '"awinic,aw8697"' "$SRC_C" || die "driver lost its compatible"
grep -q 'input_ff_create_memless' "$SRC_C" || die "driver no longer registers force feedback"
! grep -q $'\r' "$SRC_C" || die "$SRC_C has CRLF line endings"

echo "regen-op8p-aw8697: ok ($(wc -l <"$SRC_C") lines, compatible awinic,aw8697)"
rm -rf "$work"
