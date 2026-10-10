# ADR 0004 — OS detection on TOS 6: gate on `pkg_mgr`, not `os_family`

- **Status:** Accepted
- **Relation to ADR 0001:** extracts and refines Decision 8a of
  [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md)
  (the Ansible-side layered model). ADR 0001 §8 now points here.
- **Sibling platform ADRs:**
  [`0003-Tos6PrivilegeModel.md`](./0003-Tos6PrivilegeModel.md) (privilege model)
  and [`0005-AptMirrorRepoint.md`](./0005-AptMirrorRepoint.md) (apt mirror).
- **Enforced by:** `test_roles_gate_package_management_on_pkg_mgr_not_os_family`
  (repo-wide); `roles/bootstrap_base/vars/apt-family.yml`.
- **Scope:** the Ansible side only.

## Context

Confirmed on the live device (verbose `gather_facts`,
`logs/20261006T212942-access_ssh.log`): TOS 6 reports
`ansible_distribution: OtherLinux`, `ansible_distribution_release: NA`,
`ansible_distribution_version: NA`, `ansible_distribution_major_version: NA`,
`ansible_os_family: OtherLinux`, and `ansible_pkg_mgr: apt`. TOS 6 is
Ubuntu-22.04-compatible but does **not** identify as Debian/Ubuntu.

Any `os_family == 'Debian'` (or `distribution*`-based) gate silently skips on
TOS even though apt is present — the same failure class as
[ADR 0003](./0003-Tos6PrivilegeModel.md).

## Decision

Package-management decisions **must** key on
`ansible_facts['pkg_mgr'] == 'apt'` (`!=` for the non-apt path), never on
`os_family == 'Debian'`.

- The `bootstrap_base` var lookup selects `vars/apt-family.yml` via the
  `{{ ansible_facts['pkg_mgr'] }}-family.yml` candidate (renamed from
  `Debian-family.yml`), with `default.yml` as the last-resort fallback.
- This applies to `bootstrap_base`, `access_sftp`, `nixos_image_sync`, and
  `bootstrap_docker`.
- Docker's `jammy` apt suite is unaffected: it remains the correct Docker CE
  suite for TOS 6's Ubuntu-22.04 compatibility; only the install gate is keyed on
  `pkg_mgr`.

## Consequences

- A Debian/`distribution*` gate can no longer silently skip prerequisites on
  TOS 6.
- The rule is guarded repo-wide by
  `test_roles_gate_package_management_on_pkg_mgr_not_os_family`.
- OS-detection logic and OS-suite selection are decoupled: the apt suite is an
  explicit repository choice, not a fact-derived gate.

## Alternatives considered

1. **Gate on `os_family == 'Debian'` / `distribution*`.** Rejected: TOS 6 reports
   `OtherLinux` while being apt-based, so the gate silently skips and leaves
   prerequisites missing.
2. **Normalise/override the reported facts to look Debian-like.** Rejected: it
   invents an identity the device does not have and would have to be maintained
   per TOS release; the package manager is the fact that actually matters.

## References

- [`0001-HomeServer__HomeAssistant.md`](./0001-HomeServer__HomeAssistant.md) — Ansible-side architecture baseline; §8 points here.
- [`0003-Tos6PrivilegeModel.md`](./0003-Tos6PrivilegeModel.md) — sibling: TOS 6 privilege model.
- [`0005-AptMirrorRepoint.md`](./0005-AptMirrorRepoint.md) — sibling: apt mirror repoint; its explicit `jammy` suite exists because `distribution_release` is `NA`.
- [`../HomeServer__HomeAssistant_plan.md`](../HomeServer__HomeAssistant_plan.md) §3 assumptions 2 and 5 — live-device evidence.
