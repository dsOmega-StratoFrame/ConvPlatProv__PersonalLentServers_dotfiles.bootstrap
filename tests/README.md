# Tests

Four layers of testing, from cheapest to most expensive. Every major deployment
step (backup, access, base, Nix, Docker) is expected to have all of them where
they make sense.

| Layer | What it checks | Where | Needs |
|---|---|---|---|
| Unit | repository/structure invariants and role defaults | `tests/unit/` | Python (`pip install -r requirements-dev.txt`) |
| Integration | the real roles against a mock `@terra` (Ubuntu 22.04 systemd container) | `tests/integration/` | Docker + docker compose (+ sshpass) |
| E2E | the real roles against the real NAS | repo root | SSH access to `@terra` |
| Manual | human/agent debugging helpers per step | `Makefile.*` | varies |

## Unit

```sh
make unit          # python3 -m pytest tests/unit -v
```

Covers things that break silently in refactors: a role referenced by the
playbook but missing on disk, a role without `defaults/main.yml`, an unpinned
galaxy dependency, a role variable that lost its namespace, secrets that are no
longer git-ignored. No Ansible required.

## Integration

Runs the same roles against a container that mimics TOS 6 (Ubuntu-22.04-
compatible rootfs, `systemd`), with an admin user `terra`.

```sh
make it-up         # build + start the mock target (ssh on 127.0.0.1:2222)
make it-run        # run the playbook against tests/integration/inventory.ini
make it-shell      # interactive shell inside the mock target
make it-down       # stop and remove the mock target
```

Notes:

- The container needs `privileged` + host cgroups for `systemd`; see
  `tests/integration/docker-compose.yml`.
- The Nix and Docker steps are heavy (they download packages / build Nix). Run
  them deliberately, e.g. `make it-run TAGS=nix`.
- Docker-in-container cannot always start the daemon. The integration run
  covers detection and package logic; starting the daemon is an E2E concern.

## E2E

Against the actual NAS. These mutate the device, so they are the slowest and
must only run when the prerequisites in the README are met.

```sh
make run-terra            # full Layer-0 playbook
make run TAGS=nix         # one step only
make run TAGS=docker
make test                 # verify-terra.yml (idempotent assertions)
```

`make check` syntax-checks the playbooks without touching a host.

## Manual (per step)

Each step has a small makefile with mixed targets (interactive for humans,
non-interactive for agents):

```sh
make -f Makefile.BackupTos help
make -f Makefile.AccessSsh help
make -f Makefile.NixBootstrap help
make -f Makefile.DockerDeployment help
```

Common targets (defined in `Makefile.Steps`):

- `run` — apply the step (mixed)
- `dry` — `--check --diff`, no changes (agent)
- `verify` — run `verify-terra.yml` (agent)
- `up` / `down` — start/stop the mock container (agent)
- `shell` — interactive shell in the mock container (human)
- `shell-ssh` — interactive SSH to the real target (human)
- `logs` — follow mock container logs (mixed)
- `clean` — remove local test artifacts (agent)
- `run-log` — run an ad-hoc command with logging (agent)

Every ansible-running target logs to `logs/<timestamp>-<tag>.log` (and
`logs/latest.log`); `logs/` is git-ignored.

Select the target with `INVENTORY=hosts.ini` (E2E, default) or
`INVENTORY=tests/integration/inventory.ini` (integration).
