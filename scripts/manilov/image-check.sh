#!/usr/bin/env bash
# scripts/manilov/image-check.sh — read-only check of the content-addressed
# image tag and of every device (bind source) the container will mount.
#
# The tag is the first 12 hex characters of the artifact sha256 (ADR 0002). This
# script never imports, pulls, tags or removes an image: it inspects what is on
# the host and compares it with the artifact when one is supplied.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: image-check.sh [--host HOST] [--tag TAG] [--artifact PATH]

Read-only. Exits non-zero on the first failed assertion, with the fix.

  --host HOST       target host from hosts.ini (default: local)
  --tag TAG         expected 12-hex content tag (default: IMAGE_TAG from the
                    host's rendered .env, else the literal group_vars tag)
  --artifact PATH   artifact on this machine; its sha256[:12] must equal TAG

Checks:
  * the content tag format and its presence on the host (docker image inspect)
  * the running container uses exactly that tag
  * every nixos_container_mounts source exists with the declared type
EOF
}

TAG=""
TAG_SOURCE=""
ARTIFACT=""
REPO=""
ENV_FILE=""
CONTAINER=""
BACKEND=""

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag)
        [ "$#" -ge 2 ] || die "--tag needs a value"
        TAG="$2"
        TAG_SOURCE="--tag"
        shift 2
        ;;
      --tag=*)
        TAG="${1#*=}"
        TAG_SOURCE="--tag"
        shift
        ;;
      --artifact)
        [ "$#" -ge 2 ] || die "--artifact needs a value"
        ARTIFACT="$2"
        shift 2
        ;;
      --artifact=*)
        ARTIFACT="${1#*=}"
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

resolve_tag() {
  local from_env=""
  if [ -n "$TAG" ]; then
    info "using the tag from $TAG_SOURCE: $TAG"
    return 0
  fi
  if host_file_exists "$ENV_FILE"; then
    from_env="$(host_read_file "$ENV_FILE" | awk -F= '$1 == "IMAGE_TAG" { print $2; exit }')"
    if [ -n "$from_env" ]; then
      TAG="$from_env"
      TAG_SOURCE="$ENV_FILE"
      info "using the running configuration's tag from $ENV_FILE: $TAG"
      return 0
    fi
  fi
  from_env="$(vars_get_optional nixos_container_image_tag)"
  case "$from_env" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      TAG="$from_env"
      TAG_SOURCE="group_vars/nikolaigogol"
      return 0
      ;;
  esac
  die "cannot determine the content tag: the host has no $ENV_FILE yet and nixos_image_tag is a derivation. Run 'make -f Makefile.NixosContainer run' first, or pass --tag <12hex>"
}

step "inputs"
require_repo_layout
load_manilov_vars
REPO="$(vars_get nixos_container_image_repository)"
ENV_FILE="$(vars_get nixos_container_env_file)"
CONTAINER="$(vars_get nixos_container_name)"
BACKEND="$(vars_get nixos_container_docker_binary)"
require_safe_value "$REPO" "image repository"
require_safe_value "$ENV_FILE" ".env path"
require_safe_value "$CONTAINER" "container name"
require_safe_value "$BACKEND" "docker binary"
info "repository: $REPO"
info "container:  $CONTAINER"

step "content tag"
require_host
resolve_tag
require_safe_value "$TAG" "content tag"
case "$TAG" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    pass_check "tag $TAG is a 12-hex content tag"
    ;;
  *)
    fail_check "tag '$TAG' is not 12 lowercase hex characters; a content-addressed tag is sha256[:12] (ADR 0002)"
    ;;
esac

IMAGE="$REPO:$TAG"
info "image: $IMAGE"

if [ -n "$ARTIFACT" ]; then
  if [ -f "$ARTIFACT" ]; then
    if ! ARTIFACT_TAG="$(sha256_of_file "$ARTIFACT" | cut -c1-12)"; then
      fail_check "cannot hash the artifact $ARTIFACT"
    elif [ "$ARTIFACT_TAG" = "$TAG" ]; then
      pass_check "artifact $ARTIFACT hashes to $ARTIFACT_TAG"
    else
      fail_check "artifact $ARTIFACT hashes to $ARTIFACT_TAG, not $TAG; rebuild or re-tag with the shared content-tag command"
    fi
  else
    fail_check "artifact $ARTIFACT does not exist; point --artifact at the built rootfs tarball"
  fi
fi

step "image on the host"
if image_id="$(host_cmd "$BACKEND image inspect --format '{{.Id}}' '$IMAGE'" 2>/dev/null)"; then
  pass_check "$IMAGE is present on the host ($image_id)"
else
  fail_check "$IMAGE is not present on the host; run 'make -f Makefile.NixosImage run' (TAGS=image) or import the tag"
fi

if container_image="$(host_cmd "$BACKEND inspect --format '{{.Config.Image}}' '$CONTAINER'" 2>/dev/null)"; then
  case "$container_image" in
    *":$TAG")
      pass_check "container $CONTAINER runs $container_image"
      ;;
    *)
      fail_check "container $CONTAINER runs $container_image, not :$TAG; recreate the container with 'make -f Makefile.NixosContainer run'"
      ;;
  esac
else
  warn "container $CONTAINER does not exist yet; the image check above is the gate until it is created"
fi

step "devices (bind sources)"
mounts="$(parse_mounts "$MANILOV_REPO_ROOT/group_vars/nikolaigogol/vars.yml")"
if [ -z "$mounts" ]; then
  fail_check "no nixos_container_mounts entries found in group_vars/nikolaigogol/vars.yml"
fi
while IFS=$'\t' read -r source target type; do
  [ -n "$source" ] || continue
  source="$(vars_expand "$source")" || {
    fail_check "cannot resolve the mount source '$source' from group_vars"
    continue
  }
  target="$(vars_expand "$target")" || {
    fail_check "cannot resolve the mount target '$target' from group_vars"
    continue
  }
  require_safe_value "$source" "mount source"
  case "$type" in
    directory)
      if host_cmd "test -d '$source'" >/dev/null 2>&1; then
        pass_check "directory mount source $source is present (target $target)"
      else
        fail_check "directory mount source $source is missing; create it and re-run (the container role creates it on a deploy)"
      fi
      ;;
    file)
      if ! host_cmd "test -f '$source'" >/dev/null 2>&1; then
        fail_check "file mount source $source is missing; stage it (see the @Manilov image layer) before deploying the container"
      elif [ "$(host_file_size "$source")" -le 0 ]; then
        fail_check "file mount source $source is empty; re-stage it"
      else
        size="$(host_file_size "$source")"
        pass_check "file mount source $source is present ($size bytes, target $target)"
        if [ "$size" -lt 1073741824 ]; then
          warn "$source is smaller than 1 GiB; the HAOS qcow2 is ~6.35 GB, so confirm this is the staged image"
        fi
      fi
      ;;
    *)
      fail_check "mount source $source has unknown type '$type' (expected directory or file)"
      ;;
  esac
done <<<"$mounts"

step "reported, not asserted here"
if [ "$(host_cmd "test -c /dev/kvm && printf yes || printf no")" = "yes" ]; then
  info "/dev/kvm is present (KVM is checked in libvirt-check)"
else
  warn "/dev/kvm is absent; libvirt-check will fail closed because the VM needs hardware virtualisation"
fi

step "result"
finish_checks
