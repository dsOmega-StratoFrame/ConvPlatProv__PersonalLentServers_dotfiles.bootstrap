#!/usr/bin/env bash
# scripts/manilov/stage-virt-scripts.sh — populate the Virt_scripts_bootstrap
# bind mount that roles/nixos_container exposes to the @NikolaiGogol container.
#
# Idempotent (rsync --checksum), additive (never --delete) and bounded: it
# excludes every disk image, so the staged ~6.35 GB haos_ova.qcow2 can never be
# overwritten, and it verifies that after the transfer.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: stage-virt-scripts.sh [--host HOST] --source DIR [--dest DIR] [--apply]

Populate the Virt_scripts_bootstrap bind (nixos_container_virt_scripts_dir).

  --host HOST    target host from hosts.ini (default: local)
  --source DIR   local checkout of the upstream Virt_scripts_bootstrap directory
  --dest DIR     must equal nixos_container_virt_scripts_dir when given
  --apply        execute the rsync (default: --dry-run preview)

The destination must be the exact absolute bind path from group_vars, inside
zterra_root. rsync runs with --no-delete, so files that exist only on the host
(including the staged disk images) are preserved.
EOF
}

SOURCE=""
DEST=""
DEST_EXPECTED=""
ZTERRA_ROOT=""
RSYNC_EXCLUDES=()
QC_BEFORE=""
QC_AFTER=""

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        [ "$#" -ge 2 ] || die "--source needs a value"
        SOURCE="$2"
        shift 2
        ;;
      --source=*)
        SOURCE="${1#*=}"
        shift
        ;;
      --dest)
        [ "$#" -ge 2 ] || die "--dest needs a value"
        DEST="$2"
        shift 2
        ;;
      --dest=*)
        DEST="${1#*=}"
        shift
        ;;
      --host)
        [ "$#" -ge 2 ] || die "--host needs a value"
        MANILOV_HOST="$2"
        shift 2
        ;;
      --host=*)
        MANILOV_HOST="${1#*=}"
        shift
        ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done
  if [ "${#rest[@]}" -gt 0 ]; then
    parse_common_args "${rest[@]}"
  fi
  require_safe_value "$MANILOV_HOST" "host"
}

parse_script_args "$@"

canonical_dir() {
  (cd "$1" 2>/dev/null || exit 1
   pwd -P)
}

snapshot_images() {
  host_sh <<EOF
set -u
if [ -d '$DEST' ]; then
  find '$DEST' -maxdepth 2 -type f \( -name '*.qcow2' -o -name '*.qcow2.*' -o -name 'haos_ova*' \) \
    -print0 2>/dev/null | xargs -0 -r stat -c '%n	%i	%s	%Y' 2>/dev/null
fi
EOF
}

step "inputs"
require_repo_layout
load_manilov_vars
DEST_EXPECTED="$(vars_get nixos_container_virt_scripts_dir)"
ZTERRA_ROOT="$(vars_get zterra_root)"
require_safe_value "$DEST_EXPECTED" "bind path"
require_safe_value "$ZTERRA_ROOT" "zterra_root"

if [ -n "$DEST" ]; then
  DEST="${DEST%/}"
  require_safe_value "$DEST" "bind path"
  if [ "$DEST" != "$DEST_EXPECTED" ]; then
    die "refusing --dest '$DEST': the bind path must be exactly '$DEST_EXPECTED' (nixos_container_virt_scripts_dir); the container mount and this stage step cannot diverge"
  fi
else
  DEST="$DEST_EXPECTED"
fi

case "$DEST" in
  /) die "refusing to stage into /" ;;
  "$ZTERRA_ROOT"/*) : ;;
  *)
    die "refusing to stage into '$DEST': it is not under zterra_root '$ZTERRA_ROOT'; the NAS root filesystem is too small (TOS-ZTERRA-002)"
    ;;
esac

if [ -z "$SOURCE" ]; then
  die "no source checkout: pass --source DIR (the upstream Virt_scripts_bootstrap directory) or run 'make -f Makefile.Manilov stage-virt-scripts SOURCE=/path/to/Virt_scripts_bootstrap'"
fi
[ -d "$SOURCE" ] || die "source '$SOURCE' is not a directory on this machine"
SOURCE="$(canonical_dir "$SOURCE")" || die "cannot resolve the source directory '$SOURCE'"

if [ "$SOURCE" = "$DEST" ]; then
  die "source and destination are the same directory ($SOURCE)"
fi
case "$SOURCE/" in
  "$DEST"/*) die "source '$SOURCE' is inside the destination '$DEST'; refusing a recursive copy" ;;
esac

info "source: $SOURCE"
info "bind:   $DEST (host $MANILOV_HOST)"
info "mode:   $(if is_apply; then printf 'apply'; else printf 'dry-run (default)'; fi)"

step "host checks"
require_host
require_host_uid0
if host_cmd "test -L '$DEST'"; then
  die "'$DEST' is a symlink on the host; the bind source must be a real directory"
fi
if host_cmd "test -e '$DEST' && test ! -d '$DEST'"; then
  die "'$DEST' exists on the host and is not a directory"
fi
if host_cmd "test -d '$DEST'"; then
  pass_check "the bind directory exists"
else
  info "the bind directory does not exist yet; it will be created on --apply"
fi

step "staged image guard"
QC_BEFORE="$(snapshot_images)"
if [ -n "$QC_BEFORE" ]; then
  info "staged disk images (must not change):"
  printf '%s\n' "$QC_BEFORE" | while IFS=$'\t' read -r path inode size mtime; do
    info "  $path (${size} bytes, inode $inode)"
  done
else
  info "no staged disk images under $DEST"
fi

step "rsync plan"
RSYNC_EXCLUDES=(
  --exclude=.git/
  --exclude='*.qcow2'
  --exclude='*.qcow2.*'
  --exclude='haos_ova*'
  --exclude='*.img'
  --exclude='*.raw'
  --exclude='*.vdi'
  --exclude='*.incoming'
)
require_cmd rsync
rsync_args=(
  -a
  --checksum
  --no-delete
  --omit-dir-times
  --itemize-changes
  "${RSYNC_EXCLUDES[@]}"
)
if ! is_apply; then
  rsync_args+=(--dry-run)
fi

plan "rsync ${rsync_args[*]} $SOURCE/ -> $DEST/"
plan "keeps every host-only file (--no-delete) and every disk image (excludes)"

if ! is_apply; then
  info "preview (no changes):"
fi

if host_is_local; then
  rsync_out="$(rsync "${rsync_args[@]}" "$SOURCE/" "$DEST/")" || die "rsync failed; inspect the output above"
else
  if ! host_cmd "test -d '$DEST'"; then
    if is_apply; then
      plan "mkdir -p $DEST"
      host_cmd "mkdir -p '$DEST'" || die "cannot create $DEST on the host"
    else
      info "the destination does not exist; on --apply it is created before the transfer"
    fi
  fi
  rsync_out="$(rsync "${rsync_args[@]}" -e "ssh -o BatchMode=yes -o ConnectTimeout=$MANILOV_SSH_TIMEOUT" "$SOURCE/" "$MANILOV_HOST:$DEST/")" ||
    die "rsync failed; inspect the output above"
fi

if [ -n "$rsync_out" ]; then
  printf '%s\n' "$rsync_out" >&2
fi
changed="$(printf '%s\n' "${rsync_out:-}" | grep -cE '^(>|c)' || true)"
info "entries reported by rsync: $changed"

if ! is_apply; then
  require_apply
fi

step "post-transfer guard"
QC_AFTER="$(snapshot_images)"
if [ "$QC_BEFORE" != "$QC_AFTER" ]; then
  die "a staged disk image changed during the transfer; restore it from backup before restarting the VM (this must be impossible with the excludes in place)"
fi
pass_check "no staged disk image was modified"

if [ -n "$(host_cmd "test -d '$DEST' && find '$DEST' -mindepth 1 -maxdepth 1 | head -n 1" || true)" ]; then
  pass_check "the bind directory is populated"
else
  fail_check "$DEST is empty after the transfer; check --source"
fi

step "result"
finish_checks
