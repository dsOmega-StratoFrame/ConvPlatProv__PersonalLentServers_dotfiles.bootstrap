#!/usr/bin/env bash
# scripts/manilov/container.sh — render and validate the system-container compose
# definition from the deployment strategy, then (only with --apply) install it
# and bring the container up.
#
# The strategy is the repo's existing deployment surface: the role defaults and
# group_vars/nikolaigogol values (`name`, `executor`, `workspace`, `env`,
# `compose`, `privilege`, `artifact`, `identity`, `paths`, `ownership`, `pins`).
# Network mode is NOT part of that schema: the @Manilov datapath is selected by
# the image's pinned marker and owned by the `manilov-network` applier, never by
# a strategy field (ADR 0006 D7).
set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TEMPLATE="$MANILOV_SCRIPTS_DIR/templates/docker-compose-system.yml.in"
ALLOWED_FIELDS="name executor workspace env compose privilege artifact identity paths ownership pins"
OUT=""
PRINT_STRATEGY=0
SERVICE_NAME=""
CGROUP_PARENT=""
CONTAINER=""
PROJECT_DIR=""
COMPOSE_FILE=""
ENV_FILE=""
REPO=""
USERNAME=""
BACKEND=""
VOLUMES_BLOCK=""
VOLUME_COUNT=0

usage() {
  cat <<'EOF'
usage: container.sh [--host HOST] [--out PATH] [--print-strategy] [--apply]

  --host HOST        target host from hosts.ini (default: local)
  --out PATH         where to render (default: build/manilov/docker-compose-system.yml)
  --print-strategy   print the deployed strategy fields and exit (read-only)
  --apply            back up and install the compose on the host, validate it,
                     then run `docker compose up -d`

Default mode is read-only: it renders locally, validates the YAML, and reports
whether the host's compose matches the render. It never runs `docker compose
down`, and it never touches the image applier's datapath.
EOF
}

parse_script_args() {
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out)
        [ "$#" -ge 2 ] || die "--out needs a value"
        OUT="$2"
        shift 2
        ;;
      --out=*)
        OUT="${1#*=}"
        shift
        ;;
      --print-strategy)
        PRINT_STRATEGY=1
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

build_strategy() {
  local field
  SERVICE_NAME="$(vars_get nixos_container_service_name)"
  CGROUP_PARENT="$(vars_get nixos_container_cgroup_parent)"
  CONTAINER="$(vars_get nixos_container_name)"
  PROJECT_DIR="$(vars_get nixos_container_project_dir)"
  COMPOSE_FILE="$(vars_get nixos_container_compose_file)"
  ENV_FILE="$(vars_get nixos_container_env_file)"
  REPO="$(vars_get nixos_container_image_repository)"
  USERNAME="$(vars_get nixos_container_username)"
  BACKEND="$(vars_get nixos_container_docker_binary)"

  for pair in \
    "service:$SERVICE_NAME" \
    "cgroup_parent:$CGROUP_PARENT" \
    "container:$CONTAINER" \
    "project_dir:$PROJECT_DIR" \
    "compose:$COMPOSE_FILE" \
    "env:$ENV_FILE" \
    "image_repository:$REPO" \
    "username:$USERNAME" \
    "docker_binary:$BACKEND"; do
    require_safe_value "${pair#*:}" "${pair%%:*}"
  done

  STRATEGY[name]="$CONTAINER"
  STRATEGY[executor]="docker"
  STRATEGY[workspace]="$PROJECT_DIR"
  STRATEGY[env]="$ENV_FILE"
  STRATEGY[compose]="$COMPOSE_FILE"
  STRATEGY[privilege]="privileged=true cgroup=host network_mode=host cap_add=NET_ADMIN seccomp=unconfined stop_signal=SIGRTMIN+3 command=/init"
  STRATEGY[artifact]="$REPO:<content-tag>"
  STRATEGY[identity]="service=$SERVICE_NAME user=$USERNAME cgroup_parent=$CGROUP_PARENT"
  STRATEGY[paths]="$VOLUME_COUNT mount(s) from nixos_container_mounts"
  STRATEGY[ownership]="host=uid0:$(vars_get ansible_user) become=false"
  STRATEGY[pins]="content-addressed tag, resolved into $ENV_FILE by roles/nixos_container"

  for field in "${!STRATEGY[@]}"; do
    if [ "$field" = "network" ]; then
      die "the deployment strategy must not carry a 'network' field; the datapath is selected by the pinned marker (ADR 0006 D7)"
    fi
    case " $ALLOWED_FIELDS " in
      *" $field "*) : ;;
      *) die "internal error: '$field' is not a deployment-strategy field (the schema is: $ALLOWED_FIELDS)" ;;
    esac
  done
  [ "${#STRATEGY[@]}" -eq 11 ] ||
    die "internal error: the strategy must have exactly 11 fields, found ${#STRATEGY[@]}"
  pass_check "the strategy has ${#STRATEGY[@]} fields and no 'network' field"
}

build_volumes() {
  local mounts source target type
  mounts="$(parse_mounts "$MANILOV_REPO_ROOT/group_vars/nikolaigogol/vars.yml")"
  [ -n "$mounts" ] || die "no nixos_container_mounts entries in group_vars/nikolaigogol/vars.yml"
  VOLUMES_BLOCK=""
  VOLUME_COUNT=0
  while IFS=$'\t' read -r source target type; do
    [ -n "$source" ] || continue
    source="$(vars_expand "$source")" || die "cannot resolve mount source '$source'"
    target="$(vars_expand "$target")" || die "cannot resolve mount target '$target'"
    require_safe_value "$source" "mount source"
    require_safe_value "$target" "mount target"
    case "$type" in
      directory | file) : ;;
      *) die "mount '$source' has unknown type '$type' (expected directory or file)" ;;
    esac
    VOLUMES_BLOCK="$VOLUMES_BLOCK      - $source:$target"$'\n'
    VOLUME_COUNT=$((VOLUME_COUNT + 1))
  done <<<"$mounts"
  VOLUMES_BLOCK="${VOLUMES_BLOCK%$'\n'}"
  [ "$VOLUME_COUNT" -gt 0 ] || die "the container has no mounts; the HAOS image and Virt_scripts bind are required"
}

render_compose() {
  local line rendered=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *@@VOLUMES@@*)
        rendered="$rendered$VOLUMES_BLOCK"$'\n'
        ;;
      *)
        line="${line//@@SERVICE@@/$SERVICE_NAME}"
        line="${line//@@CGROUP_PARENT@@/$CGROUP_PARENT}"
        rendered="$rendered$line"$'\n'
        ;;
    esac
  done <"$TEMPLATE"
  printf '%s' "$rendered" >"$OUT"
}

validate_local() {
  if ! have_cmd docker; then
    warn "docker is not available on this machine; skipped the local 'docker compose config' validation"
    return 0
  fi
  if IMAGE_NAME="$REPO:000000000000" CONTAINER_NAME="$CONTAINER" PULL_POLICY="never" \
    docker compose -f "$OUT" config -q 2>"$WORK/compose.err"; then
    pass_check "the rendered compose validates with 'docker compose config -q'"
  else
    error "$(cat "$WORK/compose.err")"
    fail_check "the rendered compose does not validate; fix scripts/manilov/templates/docker-compose-system.yml.in"
  fi
}

step "strategy"
require_repo_layout
load_manilov_vars
make_workdir
build_volumes
build_strategy

if [ "$PRINT_STRATEGY" -eq 1 ]; then
  for field in $ALLOWED_FIELDS; do
    printf '%s=%s\n' "$field" "${STRATEGY[$field]:-}"
  done
  exit 0
fi

[ -n "$OUT" ] || OUT="$MANILOV_REPO_ROOT/build/manilov/docker-compose-system.yml"
mkdir -p "$(dirname "$OUT")"

step "render"
[ -f "$TEMPLATE" ] || die "missing template $TEMPLATE"
render_compose
ok "rendered $OUT ($VOLUME_COUNT mount(s))"

step "validate"
validate_local

step "host"
require_host
require_host_uid0
if host_file_exists "$ENV_FILE"; then
  pass_check "the host has $ENV_FILE (compose interpolates IMAGE_NAME/CONTAINER_NAME from it)"
else
  fail_check "the host has no $ENV_FILE; render the container configuration first (make -f Makefile.NixosContainer run)"
fi

host_compose="$(host_read_file "$COMPOSE_FILE")"
rendered_trim="$(<"$OUT")"
if [ -z "$host_compose" ]; then
  info "$COMPOSE_FILE is absent on the host; --apply installs the rendered definition"
  drift=1
elif [ "$(sha256_of_string "$host_compose")" = "$(sha256_of_string "$rendered_trim")" ]; then
  drift=0
else
  drift=1
fi

if [ "$drift" -eq 0 ]; then
  pass_check "the host compose matches the render"
else
  warn "the host compose differs from the render; 'make -f Makefile.NixosContainer run' is the authoritative writer (TAGS=container)"
fi

if [ "$(host_cmd "cd '$PROJECT_DIR' 2>/dev/null && '$BACKEND' compose -f '$COMPOSE_FILE' config -q 2>/dev/null && printf ok || printf fail")" = "ok" ]; then
  pass_check "the host compose validates with 'docker compose config -q'"
else
  fail_check "the host compose does not validate; re-render it with 'make -f Makefile.NixosContainer run'"
fi

plan "install $OUT -> $COMPOSE_FILE (backup first, atomic rename, mode 0640)"
plan "docker compose -f $COMPOSE_FILE config -q"
plan "docker compose -f $COMPOSE_FILE up -d"
if ! is_apply; then
  require_apply
fi

step "install"
if [ "$drift" -eq 0 ]; then
  info "the host compose already matches; no file write"
else
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  host_cmd "mkdir -p '$PROJECT_DIR'" || die "cannot create $PROJECT_DIR on the host"
  if host_file_exists "$COMPOSE_FILE"; then
    host_cmd "cp -a '$COMPOSE_FILE' '$COMPOSE_FILE.bak.$ts'" || die "cannot back up $COMPOSE_FILE on the host"
    info "backup: $COMPOSE_FILE.bak.$ts"
  fi
  tmp="$COMPOSE_FILE.tmp.$ts"
  host_write_file "$tmp" <"$OUT" || die "cannot write $tmp on the host"
  host_cmd "chmod 0640 '$tmp' && mv -f '$tmp' '$COMPOSE_FILE'" || die "cannot install $COMPOSE_FILE on the host"
  ok "installed $COMPOSE_FILE"
fi

host_cmd "$BACKEND compose -f '$COMPOSE_FILE' config -q" ||
  die "$COMPOSE_FILE does not validate on the host; restore the backup and investigate"

step "up"
host_cmd "$BACKEND compose -f '$COMPOSE_FILE' up -d" || die "'docker compose up -d' failed; inspect '$BACKEND compose -f $COMPOSE_FILE ps'"

step "result"
if [ "$(host_cmd "$BACKEND inspect --format '{{.State.Running}}' '$CONTAINER' 2>/dev/null || printf false")" = "true" ]; then
  pass_check "container $CONTAINER is running"
else
  fail_check "container $CONTAINER is not running after 'up -d'; inspect the container logs"
fi
finish_checks
