#!/usr/bin/env bash
# Regenerate patches/0030 from drivers/tfa987x.c.
#
# Same rule as the panel patch: the .c file is the source of truth, and the
# patch bundles a whole new file plus the two build-system hunks. Anything
# that extracts a file back out of a patch to edit it has truncated this
# kind of driver before.
#
# Why this driver exists at all: mainline 7.2.8 has tfa989x.c (TFA1 family,
# compatibles tfa9890/9895/9897) and tfa9879.c (a different, older chip).
# The OnePlus 8 Pro has two TFA9874, which is the TFA2 family and is not
# covered by either. This 317-line driver takes the DSP-bypass approach:
# no vendor container firmware, no hardware volume control, but it drives
# the amplifier. It is the same one the Nura/instantnoodlep port uses.
#
# Usage: scripts/regen-op8p-tfa987x-patch.sh [--check]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="${ROOT}/external-and-mods/kernel-sm8250"
SRC_C="${MOD}/drivers/tfa987x.c"
PATCH="${MOD}/patches/0030-ASoC-codecs-add-the-NXP-TFA9872-TFA9874-driver.patch"
KVER=7.2.8
TARBALL="${KSRC_TARBALL:-${ROOT}/work/cache/linux-${KVER}.tar.xz}"

REL=sound/soc/codecs
C_NAME=tfa987x.c
KCONF=SND_SOC_TFA987X

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

die() { echo "regen-op8p-tfa987x: $*" >&2; exit 1; }
[[ -f "$SRC_C" ]] || die "no driver source at $SRC_C"
[[ -f "$TARBALL" ]] || die "no kernel tarball at $TARBALL"

work="${ROOT}/work/regen-tfa987x"
rm -rf "$work"
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

# Kconfig: a new entry right before TFA989X, so the three NXP TFA entries
# stay together in alphabetical order (9879, 987X, 989X).
awk '
  /^config SND_SOC_TFA989X$/ && !done {
    print "config SND_SOC_TFA987X"
    print "\ttristate \"NXP TFA9872/TFA9874 speaker amplifiers\""
    print "\tdepends on I2C"
    print "\tselect REGMAP_I2C"
    print "\thelp"
    print "\t  Enable support for the NXP TFA9872/TFA9874 (TFA2 family)"
    print "\t  speaker amplifiers. The driver bypasses the built-in DSP, so"
    print "\t  it needs no vendor firmware and offers no hardware volume"
    print "\t  control."
    print ""
    done = 1
  }
  { print }
' "$work/a/$REL/Kconfig" >"$work/b/$REL/Kconfig"
grep -q "config $KCONF" "$work/b/$REL/Kconfig" || die "Kconfig anchor missed"

# Makefile: both the object rule and the obj-y line, next to tfa989x.
awk '
  /^snd-soc-tfa989x-y := tfa989x\.o$/ && !d1 {
    print
    print "snd-soc-tfa987x-y := tfa987x.o"
    d1 = 1
    next
  }
  { print }
' "$work/a/$REL/Makefile" >"$work/b/$REL/Makefile.tmp"
awk '
  /^obj-\$\(CONFIG_SND_SOC_TFA989X\)/ && !d2 {
    print
    print "obj-$(CONFIG_SND_SOC_TFA987X)\t+= snd-soc-tfa987x.o"
    d2 = 1
    next
  }
  { print }
' "$work/b/$REL/Makefile.tmp" >"$work/b/$REL/Makefile"
rm -f "$work/b/$REL/Makefile.tmp"
[[ "$(grep -c 'tfa987x' "$work/b/$REL/Makefile")" == 2 ]] || die "Makefile anchors missed"

cp "$SRC_C" "$work/b/$REL/$C_NAME"

( cd "$work" && diff -Naur a b >raw.patch || true )
[[ -s "$work/raw.patch" ]] || die "diff produced nothing"

# Prose header, only if the existing patch actually has one. A patch that
# starts directly with `--- a/...` has no commit message: taking "everything
# before the first ---" would then take the whole patch and the next
# generation would concatenate two complete diffs (that happened: 6 file
# headers in a 3-file patch).
header=""
if [[ -f "$PATCH" ]] && grep -qx -- '---' "$PATCH"; then
  header="$(awk '/^---$/{exit} {print}' "$PATCH")"
  if [[ "$header" == ---\ a/* || -z "$header" ]]; then
    header=""
  fi
fi
sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*$/\1 \2/; /^diff -Naur /d' \
  "$work/raw.patch" >"$work/clean.patch"
if [[ -n "$header" ]]; then
  { printf '%s\n---\n' "$header"; cat "$work/clean.patch"; } >"$work/new.patch"
else
  cp "$work/clean.patch" "$work/new.patch"
fi

if [[ $CHECK == 0 ]]; then
  if cmp -s "$work/new.patch" "$PATCH"; then
    echo "regen-op8p-tfa987x: patch already up to date"
  else
    cp "$work/new.patch" "$PATCH"
    echo "regen-op8p-tfa987x: wrote $PATCH"
  fi
fi

# verification
dec=$(awk -v f="+++ b/$REL/$C_NAME" '
  $0 == f { on = 1; next }
  on && /^\+\+\+ / { on = 0 }
  on && match($0, /\+1,[0-9]+/) { d = substr($0, RSTART + 3, RLENGTH - 3) + 0 }
  on && /^\+/ { c++ }
  END { printf "%d %d\n", d + 0, c + 0 }' "$PATCH" | { read -r d c; echo "$d $c"; })
set -- $dec
[[ "$1" -gt 0 && "$1" == "$2" ]] || die "new-file hunk says $1 lines, patch has $2"
grep -q "^+++ b/$REL/Kconfig\$" "$PATCH" || die "no Kconfig hunk"
grep -q "^+++ b/$REL/Makefile\$" "$PATCH" || die "no Makefile hunk"
grep -q 'nxp,tfa9874' "$SRC_C" || die "driver lost the tfa9874 compatible"
grep -q 'regmap_update_bits' "$SRC_C" || die "driver lost its register writes"
grep -q $'\r' "$SRC_C" && die "$SRC_C has CRLF line endings"

echo "regen-op8p-tfa987x: ok ($(wc -l <"$SRC_C") lines, compatible tfa9872+tfa9874)"
rm -rf "$work"
