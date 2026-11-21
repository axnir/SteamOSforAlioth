#!/usr/bin/env bash
# Regenerate patches/0029 from drivers/panel-samsung-ams678uw01.c and
# bindings/samsung,ams678uw01.yaml.
#
# Same rule as the ANA6706 script this replaces: the .c file is the source of
# truth. patches/0029 embeds a whole new driver (`@@ -0,0 +1,N @@`) and a whole
# new binding, and extracting a file back out of a patch to edit it truncated
# the driver three times in a row -- once dropping module_mipi_dsi_driver(),
# which left a driver that compiled, linked and never probed, with a
# -Wunused-function warning as the only symptom.
#
# The Kconfig and Makefile hunks are generated against the pristine upstream
# files, taken out of the kernel tarball the build already downloads, so the
# context is upstream's and not whatever state a build tree happens to be in.
#
# Usage: scripts/regen-op8p-panel-patch.sh [--check]
#   --check   verify the existing patch is up to date, change nothing
#
# Set KSRC_TARBALL to use a tarball other than work/cache/linux-<KVER>.tar.xz.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="${ROOT}/external-and-mods/kernel-sm8250"
SRC_C="${MOD}/drivers/panel-samsung-ams678uw01.c"
SRC_YAML="${MOD}/bindings/samsung,ams678uw01.yaml"
PATCH="${MOD}/patches/0029-drm-panel-add-the-samsung-ams678uw01-panel.patch"
KVER=7.2.8
TARBALL="${KSRC_TARBALL:-${ROOT}/work/cache/linux-${KVER}.tar.xz}"

REL_PANEL=drivers/gpu/drm/panel
REL_YAML=Documentation/devicetree/bindings/display/panel
C_NAME=panel-samsung-ams678uw01.c
Y_NAME=samsung,ams678uw01.yaml

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

die() { echo "regen-op8p-panel: $*" >&2; exit 1; }
[[ -f "$SRC_C" ]] || die "no driver source at $SRC_C"
[[ -f "$SRC_YAML" ]] || die "no binding at $SRC_YAML"
[[ -f "$TARBALL" ]] || die "no kernel tarball at $TARBALL (set KSRC_TARBALL)"

# Not mktemp: on macOS that lands under /var/folders, which a build container
# cannot see even when mounted. A directory inside work/ (git-ignored) is
# visible everywhere.
work="${ROOT}/work/regen-panel"
rm -rf "$work"
mkdir -p "$work/a/$REL_PANEL" "$work/b/$REL_PANEL" "$work/b/$REL_YAML"

# Pristine Kconfig/Makefile straight out of the tarball. One member name per
# tar invocation: passing two in one invocation silently extracted only the
# first when this ran under a container.
#
# Two tar binaries, because Git Bash's GNU tar shells out to an `xz` that is
# not installed on a default Windows box, while Windows' own bsdtar handles
# .tar.xz itself. On Linux the first candidate is the one that works.
untar_one() {
  local rel="$1" dest="$2" t
  for t in tar /c/Windows/System32/tar.exe; do
    command -v "$t" >/dev/null 2>&1 || [[ -x "$t" ]] || continue
    # strip 5 = linux-<ver> / drivers / gpu / drm / panel, leaving the file
    # name; the count is asserted below by the existence check.
    if "$t" -xJf "$TARBALL" -C "$dest" --strip-components=5 "$rel" 2>/dev/null \
       && [[ -f "$dest/$(basename "$rel")" ]]; then
      return 0
    fi
  done
  return 1
}

for f in Kconfig Makefile; do
  untar_one "linux-${KVER}/${REL_PANEL}/${f}" "$work/a/$REL_PANEL" \
    || die "cannot extract ${f} from $TARBALL"
done
cp "$work/a/$REL_PANEL/Kconfig"  "$work/b/$REL_PANEL/Kconfig"
cp "$work/a/$REL_PANEL/Makefile" "$work/b/$REL_PANEL/Makefile"

cat >>"$work/b/$REL_PANEL/Kconfig" <<'EOF'

config DRM_PANEL_SAMSUNG_AMS678UW01
	tristate "Samsung AMS678UW01 DSI cmd mode panel (OnePlus 8 Pro)"
	depends on OF
	depends on DRM_MIPI_DSI
	depends on BACKLIGHT_CLASS_DEVICE
	select DRM_DISPLAY_DSC_HELPER
	select DRM_DISPLAY_HELPER
	help
	  Say Y here if you want to enable support for the Samsung AMS678UW01
	  6.78" 1440x3168 AMOLED DSC command mode panel found in the
	  OnePlus 8 Pro.
EOF

# Insert before ATNA33XC20, which sorts right after it, so the file stays
# alphabetical. The anchor is asserted below: 7.2.8 does not have AMB655X,
# which is where the upstream patch puts it, and a silent miss produces a
# Makefile hunk that is not there at all -- the driver then builds into
# nothing and the panel simply never probes.
#
# The Makefile hunk is written by hand instead of coming out of diff(1),
# because it needs context **after** the insertion point only. Our own
# 0017 (samsung,ams667xx01) inserts a line at the same spot, so in the tree
# the kernel is actually built from, the line above the anchor is AMS667XX01
# and not AMS639RQ08. A 3-before/3-after hunk matches the pristine tarball
# and fails there -- which is exactly how the first real build of this kernel
# died (patch: "1 out of 1 hunk FAILED", Makefile.rej), after the same patch
# had passed a standalone dry run on a clean 7.2.8. Context after the anchor
# is untouched by 0017, so this hunk applies to both trees.
mf_anchor_line="$(grep -n '^obj-\$(CONFIG_DRM_PANEL_SAMSUNG_ATNA33XC20)' \
  "$work/a/$REL_PANEL/Makefile" | head -1 | cut -d: -f1)"
[[ -n "$mf_anchor_line" ]] || die "no ATNA33XC20 anchor in the panel Makefile"
{
  printf -- '--- a/%s/Makefile\n' "$REL_PANEL"
  printf -- '+++ b/%s/Makefile\n' "$REL_PANEL"
  printf -- '@@ -%d,3 +%d,4 @@\n' "$mf_anchor_line" "$mf_anchor_line"
  printf -- '+obj-$(CONFIG_DRM_PANEL_SAMSUNG_AMS678UW01) += panel-samsung-ams678uw01.o\n'
  sed -n "${mf_anchor_line},$((mf_anchor_line + 2))p" "$work/a/$REL_PANEL/Makefile" | sed 's/^/ /'
} >"$work/makefile.hunk"
grep -q 'CONFIG_DRM_PANEL_SAMSUNG_AMS678UW01' "$work/makefile.hunk" \
  || die "could not find an anchor line in the panel Makefile"

cp "$SRC_C" "$work/b/$REL_PANEL/$C_NAME"
cp "$SRC_YAML" "$work/b/$REL_YAML/$Y_NAME"

( cd "$work" && diff -Naur a b >raw.patch || true )
[[ -s "$work/raw.patch" ]] || die "diff produced nothing"

# Header text (everything before the first '---' line) is hand-written prose:
# it is the commit message, not generated.
header="$(awk '/^---$/{exit} {print}' "$PATCH" 2>/dev/null || true)"

sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*$/\1 \2/; /^diff -Naur /d' \
  "$work/raw.patch" >"$work/clean.patch"

# Splice the hand-written Makefile hunk in where diff(1) would have put it
# (after Kconfig, before the new driver), so the patch still reads in the
# order a reviewer expects.
awk -v hunk="$work/makefile.hunk" '
  /^--- a\/drivers\/gpu\/drm\/panel\/panel-samsung-ams678uw01\.c$/ && !done {
    while ((getline l < hunk) > 0) print l
    close(hunk)
    done = 1
  }
  { print }
' "$work/clean.patch" >"$work/clean2.patch"
mv -f "$work/clean2.patch" "$work/clean.patch"

if [[ -n "$header" ]]; then
  { printf '%s\n---\n' "$header"; cat "$work/clean.patch"; } >"$work/new.patch"
else
  cp "$work/clean.patch" "$work/new.patch"
fi

if [[ $CHECK == 0 ]]; then
  if cmp -s "$work/new.patch" "$PATCH"; then
    echo "regen-op8p-panel: patch already up to date"
  else
    cp "$work/new.patch" "$PATCH"
    echo "regen-op8p-panel: wrote $PATCH"
  fi
fi

# --- verification, always -------------------------------------------------
# 1. every new file's declared +1,N must equal its number of '+' lines
check_new_file() {
  local rel="$1" dec actual
  read -r dec actual < <(awk -v f="+++ b/$rel" '
    $0 == f { on = 1; next }
    on && /^\+\+\+ / { on = 0 }
    on && match($0, /\+1,[0-9]+/) { dec = substr($0, RSTART + 3, RLENGTH - 3) + 0 }
    on && /^\+/ { c++ }
    END { printf "%d %d\n", dec + 0, c + 0 }' "$PATCH")
  [[ "$dec" -gt 0 ]] || die "no '+1,N' hunk for $rel"
  [[ "$dec" == "$actual" ]] \
    || die "patch/$rel: hunk says $dec lines, patch has $actual '+' lines"
  echo "$rel: $dec lines"
}
check_new_file "$REL_PANEL/$C_NAME"
check_new_file "$REL_YAML/$Y_NAME"

# 2. both build-system hunks must be there. A driver file alone applies and
#    compiles into nothing, which looks exactly like a panel that never probes.
for f in Kconfig Makefile; do
  grep -q "^+++ b/$REL_PANEL/$f\$" "$PATCH" \
    || die "patch has no $f hunk"
done

# 3. the driver must end where a C file ends, and be brace-balanced
tail_line="$(awk -v f="+++ b/$REL_PANEL/$C_NAME" '
  $0 == f { fnd = 1; next }
  fnd && /^\+/ { last = $0 }
  END { print last }' "$PATCH" | sed 's/^+//')"
[[ "$tail_line" == 'MODULE_LICENSE("GPL");' ]] \
  || die "patch does not end with MODULE_LICENSE; got '$tail_line'"

open_c="$(grep -c '{' "$SRC_C")"
close_c="$(grep -c '}' "$SRC_C")"
[[ "$open_c" == "$close_c" ]] || die "unbalanced braces in $SRC_C: $open_c vs $close_c"

# 4. the things that have silently gone missing before, plus the two flags the
#    panel needs: without CLOCK_NON_CONTINUOUS or VIDEO_BURST it stays black
for sym in module_mipi_dsi_driver mipi_dsi_picture_parameter_set \
           mipi_dsi_compression_mode ams678uw01_on \
           MIPI_DSI_MODE_VIDEO_BURST MIPI_DSI_CLOCK_NON_CONTINUOUS; do
  grep -q "$sym" "$SRC_C" || die "driver source lost $sym"
done

# 5. the binding must still be the one this driver probes on
grep -q 'const: samsung,ams678uw01' "$SRC_YAML" \
  || die "binding lost its compatible string"
grep -q '^# SPDX-License-Identifier:' "$SRC_YAML" \
  || die "binding lost its SPDX header"

# 6. no CRLF anywhere: patch(1) on the Linux side reads these files directly,
#    and a stray CR in a Kconfig hunk applies to the wrong line
for f in "$SRC_C" "$SRC_YAML"; do
  grep -q $'\r' "$f" && die "$f has CRLF line endings"
done

echo "regen-op8p-panel: ok (driver $(wc -l <"$SRC_C") lines, braces $open_c/$close_c, symbols present)"
rm -rf "$work"
