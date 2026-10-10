# ADR 0005 — apt mirror repoint: default Ubuntu mirrors are not assumed reachable

- **Status:** Accepted
- **Relation to ADR 0001:** extracts and refines Decision 8b of
  [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md)
  (the Ansible-side layered model). ADR 0001 §8 now points here.
- **Sibling platform ADRs:**
  [`0004-Tos6OsDetection.md`](./0004-Tos6OsDetection.md) (OS detection) and
  [`0003-Tos6PrivilegeModel.md`](./0003-Tos6PrivilegeModel.md) (privilege model).
- **Enforced by:** `roles/bootstrap_base/tasks/apt_mirror.yml`; toggle
  `bootstrap_base_apt_mirror_enabled`.
- **Scope:** the Ansible side only.

## Context

The NAS network blocks the default Ubuntu mirrors (`archive.ubuntu.com` /
`security.ubuntu.com`). With untouched `/etc/apt` sources, `bootstrap_base`'s
package install hangs on connect: the `apt` module shells out to `apt-get update`
/ `apt-get -y install`, which never returns. Confirmed on the live device —
`logs/20261009T233042-base.log` ends at the "Install base packages (apt)" task.

The suite cannot be derived from facts: TOS 6 reports `distribution_release: NA`
(see [ADR 0004](./0004-Tos6OsDetection.md)).

## Decision

`bootstrap_base` **must not assume the default Ubuntu mirrors are reachable.**

It runs an **off-by-default** pre-step
(`roles/bootstrap_base/tasks/apt_mirror.yml`, imported before
`variables.yml`/`dependencies.yml`). When `bootstrap_base_apt_mirror_enabled` is
true it:

1. asserts a suite and a non-empty candidate list are configured;
2. probes `<base>/dists/<suite>/Release` for each candidate (`status_code: 200`,
   `validate_certs: false` — a reachability probe only, since `ca-certificates`
   may not be installed yet);
3. selects the first candidate answering 200, and fails with guidance if none do;
4. rewrites **only Ubuntu hostnames**
   (`https?://(archive|security|ports)\.ubuntu\.com/ubuntu`) in the `/etc/apt`
   source files, with `backup: true`.

The suite is explicit (`jammy`) because TOS 6 reports `distribution_release: NA`
([ADR 0004](./0004-Tos6OsDetection.md)), so it cannot be derived from facts.
Non-Ubuntu sources — TOS's own repo, Docker's — are deliberately out of scope, so
the change cannot disturb the appliance's own package feeds. `@terra` enables the
feature in `group_vars/terra/vars.yml`; every other host keeps the role default
(`false`).

## Consequences

- The opt-in default keeps the role deterministic for hosts whose default mirrors
  work.
- The Ubuntu-hostname scope plus per-file backups bound the blast radius;
  rollback is to restore the timestamped `backup` copy next to each edited
  `/etc/apt` source file (or clear `bootstrap_base_apt_mirror_enabled`).
- **Residual risk / fallback:** if `apt-get` still stalls once a reachable mirror
  has been selected, the TOS `apt`/`apt-get` wrapper (`/etc/tos/scripts/apt*`) is
  intercepting the call and stdin would have to be fed `yes`; that is not
  implemented.

## Alternatives considered

1. **Assume the default Ubuntu mirrors are reachable.** Rejected: confirmed to
   hang on `@terra`; `apt` never returns.
2. **Rewrite all apt sources, not only Ubuntu hostnames.** Rejected: TOS's own
   repo and Docker's feed are deliberately left untouched so the appliance's
   package feeds cannot be disturbed.
3. **Derive the suite from `distribution_release`.** Rejected: TOS 6 reports
   `NA` (ADR 0004), so the suite must be explicit.

## References

- [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md) — Ansible-side architecture baseline; §8 points here.
- [`0004-Tos6OsDetection.md`](./0004-Tos6OsDetection.md) — sibling: OS detection on TOS 6 (why the suite is explicit).
- [`0003-Tos6PrivilegeModel.md`](./0003-Tos6PrivilegeModel.md) — sibling: TOS 6 privilege model.
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md) §3 assumption 6 — live-device evidence and rollback.
