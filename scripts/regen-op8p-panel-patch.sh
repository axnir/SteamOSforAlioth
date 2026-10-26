#!/usr/bin/env bash
# Regenerate patches/0029 from drivers/panel-oneplus-ana6706.c.
#
# Why this exists: patches/0029 embeds a whole new file (`@@ -0,0 +1,N @@`),
# and the driver was repeatedly edited by extracting it back out of the
# patch, editing, and re-diffing. That round-trip silently truncated the
# tail three times -- once dropping module_mipi_dsi_driver(), which left a
# driver that compiled, linked, and never probed. Each time the only
# symptom was a `-Wunused-function` warning that was easy to miss.
#
# So: the source of truth is the .c file. Never edit the patch by hand and
# never extract a file out of a patch to edit it. Run this instead.
#
# Kconfig and Makefile are regenerated from the kernel tarball that the
# build already downloaded, so the diff baseline is always the pristine
# upstream file rather than whatever state the build tree happens to be in.
#
# Usage: scripts/regen-op8p-panel-patch.sh [--check]
#   --check   verify the existing patch is up to date, change nothing
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/external-and-mods/kernel-sm8250/drivers/panel-oneplus-ana6706.c"
PATCH="${ROOT}/external-and-mods/kernel-sm8250/patches/0029-drm-panel-add-the-samsung-ana6706-panel.patch"
VOL=steamlink-build
REL=drivers/gpu/drm/panel

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

die() { echo "regen-op8p-panel: $*" >&2; exit 1; }
[[ -f "$SRC" ]] || die "no driver source at $SRC"

# Header text (everything before the first '---' line) is preserved verbatim:
# it is the commit message and it is hand-written prose, not generated.
header="$(awk '/^---$/{exit} {print}' "$PATCH")"
[[ -n "$header" ]] || die "cannot find the patch header in $PATCH"

# Not mktemp: on macOS that lands under /var/folders, which the container
# cannot see even when mounted, so the diff silently disappeared. Use a
# directory inside the repo instead (git-ignored via work/).
work="${ROOT}/work/regen-panel"
rm -rf "$work"
mkdir -p "$work"
# Cleanup is at the very end, not via a trap: an EXIT trap fired while the
# container's bind mount was still the live directory, and the observed
# symptom was `sed: .../panel.patch: No such file or directory` from a run
# that had in fact produced the diff.

if [[ $CHECK == 0 ]]; then
  docker run --rm \
    -v "$VOL:/work:ro" \
    -v "$SRC:/src/driver.c:ro" \
    -v "$work:/out" \
    fedora:43 bash -c '
set -e
dnf -q -y install diffutils tar xz >/dev/null 2>&1
cd /tmp && mkdir cl && cd cl
# Pristine Kconfig/Makefile straight out of the tarball the build cached.
# One tar invocation per file: passing two member names in one
# invocation silently extracted only the first here.
tar -xf /work/kernel-sm8250/cache/linux-7.2.8.tar.xz linux-7.2.8/'"$REL"'/Kconfig
tar -xf /work/kernel-sm8250/cache/linux-7.2.8.tar.xz linux-7.2.8/'"$REL"'/Makefile
mkdir -p a/'"$REL"' b/'"$REL"'
cp linux-7.2.8/'"$REL"'/Kconfig  a/'"$REL"'/Kconfig
cp linux-7.2.8/'"$REL"'/Makefile a/'"$REL"'/Makefile
cp linux-7.2.8/'"$REL"'/Kconfig  b/'"$REL"'/Kconfig
cp linux-7.2.8/'"$REL"'/Makefile b/'"$REL"'/Makefile

printf "\nconfig DRM_PANEL_ONEOPLUS_ANA6706\n\ttristate \"Samsung ANA6706 panel (OnePlus 8 Pro)\"\n\tdepends on OF\n\tdepends on DRM_MIPI_DSI\n\tselect DRM_DISPLAY_DSI_HELPER\n\tselect DRM_DISPLAY_DSC_HELPER\n\thelp\n\t  Say Y here if you want support for the Samsung ANA6706 panel,\n\t  as used on the OnePlus 8 Pro.\n" >> b/'"$REL"'/Kconfig
echo "obj-\$(CONFIG_DRM_PANEL_ONEOPLUS_ANA6706) += panel-oneplus-ana6706.o" >> b/'"$REL"'/Makefile
cp /src/driver.c b/'"$REL"'/panel-oneplus-ana6706.c

diff -Naur a b > /out/panel.patch || true
' || die "container step failed"

  sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*$/\1 \2/; /^diff -Naur /d' \
    "$work/panel.patch" > "$work/clean.patch"

  { printf '%s\n---\n' "$header"; cat "$work/clean.patch"; } > "$PATCH"
  echo "regen-op8p-panel: wrote $PATCH"
fi

# --- verification, always -------------------------------------------------
# 1. the declared +N must equal the number of '+' lines
declared="$(grep -oE '^@@ -0,0 \+1,[0-9]+ @@' "$PATCH" | grep -oE '[0-9]+' | tail -1)"
actual="$(awk '/^\+\+\+ b\/'"${REL//\//\\/}"'\/panel-oneplus-ana6706\.c$/{f=1;next}
              f && /^\+/{c++} f && /^--- a\//{f=0} END{print c+0}' "$PATCH")"
[[ -n "$declared" ]] || die "no '+1,N' hunk in $PATCH"
[[ "$declared" == "$actual" ]] \
  || die "line count mismatch: header says $declared, patch has $actual '+' lines"

# 2. the file must end where a C file ends, and be brace-balanced
tail_line="$(awk '/^\+\+\+ b\/'"${REL//\//\\/}"'\/panel-oneplus-ana6706\.c$/{f=1;next}
                  f && /^\+/{last=$0} END{print last}' "$PATCH" | sed 's/^+//')"
[[ "$tail_line" == "MODULE_LICENSE(\"GPL\");" ]] \
  || die "patch does not end with MODULE_LICENSE; got '$tail_line'"

open_c="$(grep -c '{' "$SRC")"
close_c="$(grep -c '}' "$SRC")"
[[ "$open_c" == "$close_c" ]] || die "unbalanced braces in $SRC: $open_c vs $close_c"

# 3. the things that have silently gone missing before
for sym in module_mipi_dsi_driver mipi_dsi_picture_parameter_set \
           mipi_dsi_compression_mode ana6706_init_sequence; do
  grep -q "$sym" "$SRC" || die "driver source lost $sym"
done

echo "regen-op8p-panel: ok ($declared lines, braces $open_c/$close_c, symbols present)"
rm -rf "$work"
