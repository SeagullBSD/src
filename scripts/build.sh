#!/bin/ksh
set -eu

usage() {
	print 'usage: [WORKDIR=/path] [CVSROOT=...] [MAKE_JOBS=n] build-generic-mp.sh [--help]'
	print 'Fetches OpenBSD 8.0, applies the seagull patch series, and builds GENERIC.MP.'
	print 'Defaults: WORKDIR=../work/openbsd-8.0-generic-mp, CVSROOT=anoncvs@anoncvs.jp.openbsd.org:/cvs, MAKE_JOBS=2'
}

fatal() {
	print -u2 "$*"
	exit 1
}

if [[ $# -gt 0 ]]; then
	case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
fi

[[ $(uname -s) == OpenBSD ]] || fatal 'run this script on OpenBSD'

for command_name in cvs patch config make file sha256 cmp; do
	command -v "$command_name" >/dev/null 2>&1 || fatal "missing required command: $command_name"
done

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)
PATCH_DIR=$ROOT/patches
CVSROOT=${CVSROOT:-anoncvs@anoncvs.jp.openbsd.org:/cvs}
CVS_TAG=OPENBSD_8_0
WORKDIR=${WORKDIR:-$ROOT/work/openbsd-8.0-generic-mp}
MAKE_JOBS=${MAKE_JOBS:-2}
CVS_RSH=${CVS_RSH:-ssh}
export CVS_RSH

case "$MAKE_JOBS" in
''|*[!0-9]*) fatal 'MAKE_JOBS must be a positive integer' ;;
esac
case "$MAKE_JOBS" in
*[1-9]*) ;;
*) fatal 'MAKE_JOBS must be greater than zero' ;;
esac

case "$WORKDIR" in
/*) ;;
*) WORKDIR=$ROOT/$WORKDIR ;;
esac
[[ "$WORKDIR" != / && "$WORKDIR" != "$ROOT" ]] || fatal 'WORKDIR must be a dedicated directory'
mkdir -p "$WORKDIR"
WORKDIR=$(CDPATH= cd "$WORKDIR" && pwd -P)
[[ "$WORKDIR" != / && "$WORKDIR" != "$ROOT" ]] || fatal 'WORKDIR must be a dedicated directory'

SRC=$WORKDIR/src
OBJ=$WORKDIR/obj/GENERIC.MP
PATCH_STATE=$WORKDIR/.seagull-patch-state
PATCH_STATE_TMP=$WORKDIR/.seagull-patch-state.$$
trap 'rm -f "$PATCH_STATE_TMP"' 0

set -- \
	"$PATCH_DIR/0001-drm-core.diff" \
	"$PATCH_DIR/0001-z-amdgpu-slab.diff" \
	"$PATCH_DIR/0002-kernel-mmap.diff" \
	"$PATCH_DIR/0003-drm-policy.diff" \
	"$PATCH_DIR/0004-arm64-dma-rtkit.diff" \
	"$PATCH_DIR/0004-rtkit-mailbox.diff" \
	"$PATCH_DIR/0005-arm64-no-bounce.diff" \
	"$PATCH_DIR/0005-rtkit-clients.diff" \
	"$PATCH_DIR/0006-asahi-agx.diff"

: > "$PATCH_STATE_TMP"
for patch_file in "$@"; do
	[[ -r "$patch_file" ]] || fatal "cannot read patch: $patch_file"
	printf '%s  %s\n' "$(sha256 -q "$patch_file")" "${patch_file##*/}" >> "$PATCH_STATE_TMP"
done

source_present=no
if [[ -d "$SRC" ]]; then
	source_present=yes
elif [[ -e "$SRC" ]]; then
	fatal "source path exists but is not a directory: $SRC"
else
	print "Fetching OpenBSD $CVS_TAG into $SRC"
	(cd "$WORKDIR" && cvs -Q -d "$CVSROOT" checkout -r "$CVS_TAG" -P src)
fi

[[ -d "$SRC/CVS" && -f "$SRC/CVS/Tag" && -f "$SRC/sys/conf/files" ]] || \
	fatal "incomplete CVS source tree: $SRC (remove it or select a fresh WORKDIR)"
source_tag=$(cat "$SRC/CVS/Tag")
[[ "$source_tag" == "T$CVS_TAG" ]] || \
	fatal "expected CVS tag T$CVS_TAG in $SRC/CVS/Tag; found $source_tag"

if [[ "$source_present" == yes && -f "$PATCH_STATE" ]]; then
	cmp -s "$PATCH_STATE" "$PATCH_STATE_TMP" || \
		fatal "patch set differs from the existing work tree; choose a fresh WORKDIR"
	print 'Using the previously patched source tree.'
else
	if [[ "$source_present" == no && -e "$PATCH_STATE" ]]; then
		rm -f "$PATCH_STATE"
	fi
	if [[ -e "$PATCH_STATE" ]]; then
		fatal "patch application is incomplete or untracked; choose a fresh WORKDIR"
	fi
	print 'Checking and applying the patch series:'
	printf '%s\n' 'patches are applied in the order listed below' > "$PATCH_STATE"
	for patch_file in "$@"; do
		print "  ${patch_file##*/}"
		patch -C -f -s -V none -p0 -d "$SRC" -i "$patch_file"
		patch -f -s -V none -p0 -d "$SRC" -i "$patch_file"
	done
	cp "$PATCH_STATE_TMP" "$PATCH_STATE"
fi

CONF=$SRC/sys/arch/arm64/conf/GENERIC.MP
[[ -f "$CONF" ]] || fatal "GENERIC.MP kernel configuration not found: $CONF"
	print 'Note: stock GENERIC.MP has no aplagx device entry; AGX driver objects are not compiled.'

# Avoid host-specific compiler and make overrides.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CC CXX MAKEFLAGS
mkdir -p "$OBJ"
print 'Generating the GENERIC.MP kernel build directory.'
(cd "$SRC/sys/arch/arm64/conf" && config -b "$OBJ" -s "$SRC/sys" GENERIC.MP)
print "Building GENERIC.MP with $MAKE_JOBS job(s)."
(cd "$OBJ" && make -j"$MAKE_JOBS")

[[ -f "$OBJ/bsd" ]] || fatal "kernel build completed without producing $OBJ/bsd"
file "$OBJ/bsd"
sha256 "$OBJ/bsd"
print "Build complete: $OBJ/bsd"
