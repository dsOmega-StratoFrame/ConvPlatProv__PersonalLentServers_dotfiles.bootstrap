#!/usr/bin/env bash
# scripts/manilov/libvirt-check.sh — read-only verification of the libvirt/KVM
# prerequisites inside the @NikolaiGogol image that hosts the @Manilov VM.
#
# Nothing is started, defined, edited or removed. The VM lifecycle (definition,
# start, tap attachment) is not owned by this repo: the tap is rendered by the
# `manilov-network` applier and the domain comes from Virt_scripts_bootstrap.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: libvirt-check.sh [--host HOST] [--container NAME] [--vm NAME]

Read-only. Exits non-zero on any failed assertion, with the fix.

  --host HOST        target host from hosts.ini (default: local)
  --container NAME   system container (default: nixos_container_name)
  --vm NAME          libvirt domain (default: manilov_vm_name)

Checks inside the image: libvirtd, the qemu:///system connection, /dev/kvm, the
kvm domain type, the domain's existence, and the HAOS image at its bind target.
EOF
}

CONTAINER=""
VM=""
IMAGE_SOURCE=""
IMAGE_TARGET=""
BACKEND=""
declare -A CTRFACT=()

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --container)
        [ "$#" -ge 2 ] || die "--container needs a value"
        CONTAINER="$2"
        shift 2
        ;;
      --container=*)
        CONTAINER="${1#*=}"
        shift
        ;;
      --vm)
        [ "$#" -ge 2 ] || die "--vm needs a value"
        VM="$2"
        shift 2
        ;;
      --vm=*)
        VM="${1#*=}"
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

resolve_file_mount() {
  local mounts source target type
  mounts="$(parse_mounts "$MANILOV_REPO_ROOT/group_vars/nikolaigogol/vars.yml")"
  while IFS=$'\t' read -r source target type; do
    [ "$type" = "file" ] || continue
    IMAGE_SOURCE="$(vars_expand "$source")" || die "cannot resolve the file mount source '$source'"
    IMAGE_TARGET="$(vars_expand "$target")" || die "cannot resolve the file mount target '$target'"
    require_safe_value "$IMAGE_SOURCE" "file mount source"
    require_safe_value "$IMAGE_TARGET" "file mount target"
  done <<<"$mounts"
}

step "inputs"
require_repo_layout
load_manilov_vars
make_workdir
[ -n "$CONTAINER" ] || CONTAINER="$(vars_get nixos_container_name)"
[ -n "$VM" ] || VM="$(vars_get manilov_vm_name)"
BACKEND="$(vars_get nixos_container_docker_binary)"
resolve_file_mount
require_safe_value "$CONTAINER" "container name"
require_safe_value "$VM" "VM name"
require_safe_value "$BACKEND" "docker binary"
info "container: $CONTAINER (host $MANILOV_HOST)"
info "domain:    $VM"
info "image:     $IMAGE_SOURCE -> $IMAGE_TARGET"

step "host"
require_host
if [ "$(host_cmd "$BACKEND inspect --format '{{.State.Running}}' '$CONTAINER' 2>/dev/null || printf false")" = "true" ]; then
  pass_check "container $CONTAINER is running"
else
  fail_check "container $CONTAINER is not running; start it with 'make -f Makefile.NixosContainer run' before checking libvirt"
  finish_checks
fi

step "libvirt inside the image"
facts="$(
  ctr_sh "$CONTAINER" <<'EOF'
PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/usr/local/bin:/usr/bin:/bin
export PATH
emit() { printf '%s\t%s\n' "$1" "$2"; }
emit libvirtd "$(systemctl is-active libvirtd 2>/dev/null || systemctl is-active virtqemud 2>/dev/null || true)"
emit virsh "$(command -v virsh >/dev/null 2>&1 && echo yes || echo no)"
emit connection "$(virsh -c qemu:///system version >/dev/null 2>&1 && echo ok || echo fail)"
emit kvm "$(if [ -c /dev/kvm ]; then echo yes; else echo no; fi)"
emit kvm_domain "$(virsh -c qemu:///system capabilities 2>/dev/null | grep -c "domain type='kvm'" || true)"
EOF
)"
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] || continue
  CTRFACT["$key"]="$value"
done <<<"$facts"

case "${CTRFACT[libvirtd]:-}" in
  active) pass_check "libvirtd is active inside the image" ;;
  *) fail_check "libvirtd is '${CTRFACT[libvirtd]:-unknown}' inside the image; the image must enable virtualisation.libvirtd" ;;
esac

if [ "${CTRFACT[virsh]:-no}" = "yes" ]; then
  pass_check "virsh is available inside the image"
else
  fail_check "virsh is not on PATH inside the image; the image's libvirt package is missing"
fi

if [ "${CTRFACT[connection]:-fail}" = "ok" ]; then
  pass_check "qemu:///system answers"
else
  fail_check "virsh cannot connect to qemu:///system; check that the container is privileged with cgroup: host and that /var/run/libvirt/libvirt-sock exists"
fi

if [ "${CTRFACT[kvm]:-no}" = "yes" ]; then
  pass_check "/dev/kvm is a character device inside the image"
else
  fail_check "/dev/kvm is missing inside the image; enable VT-x/AMD-V in the NAS firmware, load kvm on @terra, and recreate the container (the device must exist on the host)"
fi

kvm_domain_count="${CTRFACT[kvm_domain]:-0}"
case "$kvm_domain_count" in
  '' | *[!0-9]*) kvm_domain_count=0 ;;
esac
if [ "$kvm_domain_count" -gt 0 ]; then
  pass_check "libvirt advertises the kvm domain type"
else
  fail_check "libvirt does not advertise a kvm domain; @Manilov cannot run on TCG, so fix /dev/kvm and the kvm module first"
fi
step "domain"
if ctr_sh "$CONTAINER" <<EOF
PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/usr/bin:/bin
export PATH
virsh -c qemu:///system dominfo '$VM' >/dev/null 2>&1
EOF
then
  pass_check "domain $VM is defined"
  state="$(
    ctr_sh "$CONTAINER" <<EOF
PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/usr/bin:/bin
export PATH
virsh -c qemu:///system domstate '$VM' 2>/dev/null | head -n 1
EOF
  )"
  info "domain $VM state: ${state:-unknown}"
else
  fail_check "domain $VM is not defined; the VM definition is owned by Virt_scripts_bootstrap (this repo does not create it)"
fi

step "bind mount"
source_size="$(host_file_size "$IMAGE_SOURCE")"
if [ "${source_size:-0}" -le 0 ] 2>/dev/null; then
  fail_check "the host file $IMAGE_SOURCE is missing or empty; stage the HAOS image before checking the bind"
fi
target_size="$(
  ctr_sh "$CONTAINER" <<EOF
PATH=/run/current-system/sw/bin:/usr/bin:/bin
export PATH
stat -c %s '$IMAGE_TARGET' 2>/dev/null || printf 0
EOF
)"
if [ "${target_size:-0}" -gt 0 ] 2>/dev/null; then
  if [ "${target_size}" = "${source_size}" ]; then
    pass_check "$IMAGE_TARGET is visible inside the image (${target_size} bytes, matches the host file)"
  else
    fail_check "$IMAGE_TARGET inside the image is ${target_size} bytes but the host file is ${source_size}; the bind is stale or shadowed"
  fi
else
  fail_check "$IMAGE_TARGET is absent inside the image; check the nixos_container_mounts file source and recreate the container"
fi

step "result"
finish_checks
