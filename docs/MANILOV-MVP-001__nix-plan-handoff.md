# MANILOV-MVP-001 — nix-plan handoff (2026.11.02)

**Task ID:** `MANILOV-MVP-001-NIXPLAN`
**Owning repo:** `Unix_dotfiles`
**Author:** nix-analyst (handoff to the `nix-plan` agent in another harness)
**Status:** ready for planning; no implementation performed here
**Constraint:** self-contained. The receiving harness has `Unix_dotfiles` but cannot read `PersonalLentServers%Russian_dotfiles.bootstrap`, cannot SSH, and must not resolve `terra-local` or reach `@terra`/`@salt`.

## TL;DR

Add one shared, host-independent network module to `Unix_dotfiles`, imported by both `systems/x86_64-docker/NikolaiGogol` and `systems/x86_64-linux/NikolaiGogol_inner`. Ship one image containing two immutable runtime profiles (`proxyarp`, `bridge`), selected only by a pinned, hashed marker file bind-mounted read-only. Provide one versioned applier with `check` / `apply` / `status` / `rollback`. Everything below is verifiable locally in `Unix_dotfiles`: `nix flake check`, `nix eval` assertions, `nix build`, sandbox-safe unit tests, and an optional network-namespace tier.

---

## 1. Task identity and scope

**In scope**
- One shared NixOS module for the Manilov datapath, single-sourced.
- The two immutable profiles and their data.
- The marker schema, canonical selector digest, and digest allowlist.
- The `manilov-network` applier (`check`/`apply`/`status`/`rollback`/`watchdog`).
- systemd service + watchdog service + timer.
- The image-owned nft table and VM-path rules.
- Parity between `NikolaiGogol` and `NikolaiGogol_inner`.
- Fixtures and tests.
- Exactly one image rebuild to add the module.

**Out of scope (do not touch)**
- `PersonalLentServers%Russian_dotfiles.bootstrap` and every file in it.
- SSH, `@terra`, `@salt`, `terra-local`, any live host.
- Container lifecycle, image publishing/pushing, registry credentials.
- libvirt domain definition, VM XML, or `qemu` options beyond what the existing module already imports.
- `Virt_scripts_bootstrap` edits.
- Host-side `Unmanaged=yes` drop-in writer, host rescue timer, host networkd changes (the bootstrap repo owns these).
- `ConvPlatProv__HomeAssistant` and any other project.

**Target systems**
- `systems/x86_64-docker/NikolaiGogol` — durable image system. Expected flake output: `dockerConfigurations.NikolaiGogol` (confirm with `nix flake show`).
- `systems/x86_64-linux/NikolaiGogol_inner` — edge-rebuild fork. Expected flake output: `nixosConfigurations.NikolaiGogol_inner`.

**Findings this plan encodes**
- **F1 = C′.** The `@NikolaiGogol` image owns `br0`, `tap0`/proxyARP, the L3 move, the MAC pin, the VM-path FORWARD rules, and the VM tap attachment. The host owns only the global firewall, SSH/`INPUT_PROTECT`, the `@terra`–`@salt` transport, the one-time uplink relinquish, and the rescue. ADR: `PersonalLentServers%Russian_dotfiles.bootstrap/docs/adr/0006-ManilovNetworkOwnership.md`.
- **F3.** One host-independent image, no per-host fork; exactly one rebuild to add the network module is acceptable.
- **F4.** `NikolaiGogol` is the durable image system; `NikolaiGogol_inner` is an edge-rebuild fork of the same system. The network module moves into a shared module imported by both; `_inner` keeps importing it for the edge loop.

---

## 2. Inputs available to the harness

Readable in `Unix_dotfiles`:
- `systems/x86_64-docker/NikolaiGogol/default.nix`
- `systems/x86_64-linux/NikolaiGogol_inner/default.nix` — existing proxyARP pattern at lines 47–70; `qemu.runAsRoot = true` at line 131.
- `lib/` and `lib/modules/default.nix` — category/opt-in conventions; `runtime-home-bridge` shows the `extraPredicate = { module-cfg, ... }: module-cfg ? enable;` pattern.
- Existing `modules/nixos/services/*` for module shape, `checks/*` for check shape, `flake.nix` for output wiring.

Topology variables (no concrete IPs/MACs may be embedded):
- `@terra`: one connected Ethernet NIC (`eth1`), one unconnected slot (`eth0`); host `systemd-networkd` with per-MAC `.network` and `ClientIdentifier=mac`; SSH 9222 with `INPUT_PROTECT` limited to the management subnet; `br_netfilter` built in, `bridge-nf-call-*=1`, nft `FORWARD` policy `drop`; no container/libvirt yet.
- `@salt`: Wi-Fi station (`wlan0`) + `tap0` + proxyARP + `tap0 ↔ wlan0` forwarding; the existing pattern at `systems/x86_64-linux/NikolaiGogol_inner/default.nix:47-70`; `qemu.runAsRoot = true` at `:131`.

Hard rule: the harness must not need the Ansible repo, must not resolve `terra-local`, and must not reach any host.

---

## 3. Design decisions (normative)

- **D1 — Single shared module.** One module directory imported by both systems. No duplicated profile logic, no per-host fork, no copy of `default.nix`.
- **D2 — One image, two profiles.** Profiles are immutable data inside the image (`profiles.json`), not build-time branches. The image derivation must not depend on which profile will run. Marker selection is runtime-only.
- **D3 — Marker is the only selector.** `DEPLOY_HOST`, hostname, `/etc/hosts`, `/etc/machine-id`, environment variables, and systemd conditionals must never select the profile.
- **D4 — Marker is pinned by a selector digest.** The image embeds an allowlist of canonical selector objects per profile. The applier recomputes the digest and fails closed if it is not in the allowlist.
- **D5 — Host-specific values live only in `marker.params`.** No IP, MAC, interface name, or hostname literal in Nix. Image-owned names (`br0`, `tap0`, `manilov_vm`) are constants and allowed.
- **D6 — The image never writes host files.** The host `Unmanaged` drop-in, host rescue timer, and host networkd are bootstrap-owned. The image only reads a read-only host-networkd view.
- **D7 — Firewall is additive and scoped.** The image owns exactly one nft table (`inet manilov_vm`) and never flushes or edits the host ruleset or `DOCKER-*` chains.
- **D8 — Applier is the only mutator.** All netlink/nft changes go through `manilov-network`; units call the applier; nothing else writes network state.
- **D9 — Dead-man = rollback.** The image watchdog runs `check` and rolls back on failure; the host rescue timer is the bootstrap's dead-man. They meet at `state.json.phase`.
- **D10 — Multi-container (aligned with ADR 0007).** v1 implements exactly one `role: "owner"` per host. The schema carries `role` and `owner={kind,id,container,image}`. `role: "consumer"` is supported read-only: `check` and `status` exit 0; `apply` and `rollback` exit 12. Additional consumers require no schema change.

---

## 4. Deliverables

### 4.1 Shared module boundary

Proposed path: `modules/nixos/services/manilov-network/` (follow the nearest existing convention if the repo prefers `modules/nixos/networking/`; keep it single-sourced either way).

Files (names indicative):
- `default.nix` — options, imports, unit wiring, `environment.etc."manilov/profiles.json"`, applier package.
- `profiles.nix` — pure data for `proxyarp` and `bridge`; no host values.
- `applier.nix` — `writeShellApplication` (or equivalent) with pinned `runtimeInputs` (`iproute2`, `nftables`, `jq`, `coreutils`, `gnugrep`, `gawk`).
- `schema/marker.schema.json`, `schema/status.schema.json`, `schema/state.schema.json`.

Options (exact names to confirm against repo style; these are the contract):
- `services.manilov-network.enable` — bool, default `false`; opt-in via `lib.ds-omega.modules.services.manilov-network = enabled;` and/or explicit `enable`, following the `runtime-home-bridge` pattern.
- `services.manilov-network.imageId` — string, default `"nikolaigogol"`.
- `services.manilov-network.applierVersion` — string, default `"1.0.0"`.
- `services.manilov-network.markerPath` — string, default `"/etc/manilov/marker.json"`.
- `services.manilov-network.stateDir` — string, default `"/var/lib/manilov-network"`.
- `services.manilov-network.hostNetworkdView` — string, default `"/run/manilov/host-networkd"`.
- `services.manilov-network.watchdogInterval` — string, default `"30s"`.
- `services.manilov-network.profiles` — read-only, derived; the two profile specs.
- `services.manilov-network.allowedSelectors` — read-only, derived; digest allowlist.
- `services.manilov-network.effective` — read-only pure attrset used by parity tests.

Forbidden options: any `buildProfile`, `activeProfile`, `defaultProfile`, `mode`, or `hostName` that changes the image derivation. A test asserts these do not exist.

Export a stable `modulePath` (e.g. `toString ./default.nix`) so parity can prove both systems import the same file.

### 4.2 The two immutable profiles

**`proxyarp`** (the `@salt` shape, generalized):
- Resolve `UPLINK` from `params.uplink.name`; verify the permanent MAC if `params.uplink.expectPermanentMac` is set.
- Create `tap0` with the pinned locally-administered MAC (`params.datapath.tapMac`); set `proxy_arp=1` on `UPLINK`; enable IPv4 forwarding on `UPLINK` and `tap0`; install the VM-path rules for `tap0 ↔ UPLINK`.
- No bridge, no L3 move from the host; the host keeps its address.

**`bridge`** (the `@terra` shape, generalized):
- Precondition: a host `Unmanaged` drop-in matching `params.management.permanentMac` is visible in the read-only host-networkd view.
- Resolve `UPLINK`; require no L3 on `UPLINK` (host relinquished); create `br0`, enslave `UPLINK`, apply `params.addressing` to `br0`, pin the `br0` MAC (`params.datapath.bridgeMac`), create `tap0` attached to `br0`, install the VM-path rules.
- `rollback` removes `br0`/`tap0`, flushes only `inet manilov_vm`, writes `handoff.to = "host"`, and leaves `UPLINK` up but unaddressed so host networkd can reclaim it once the bootstrap removes the drop-in.

Both profiles are ordered op lists in `profiles.nix`. The applier interprets one op vocabulary (`link.add`, `link.set`, `link.master`, `addr.add`, `sysctl.set`, `nft.load`, …). No profile-specific code paths beyond the op interpreter.

### 4.3 Marker schema (v1)

Path: `/etc/manilov/marker.json`, bind-mounted read-only by the bootstrap.

Top-level fields:
- `schema` — string, must equal `"manilov.network.marker/v1"`.
- `profile` — enum `["proxyarp","bridge"]`.
- `role` — enum `["owner","consumer"]`; only `"owner"` may mutate. `"consumer"` is read-only: `check`/`status` exit 0, `apply`/`rollback` exit 12.
- `owner` — object `{ "kind": "image"|"host", "id": string, "container"?: string, "image"?: string }`. For `role=owner`, `kind` must be `"image"` and `id` must equal `imageId`; `container`/`image` bind the designation to the running container and image digest (ADR 0007).
- `selectorDigest` — string `"sha256:<64 hex>"`; digest of the canonical selector subset.
- `params` — object; host-specific; schema-validated but not part of `selectorDigest`.

Canonical selector subset: exactly `{schema, profile, role, owner}`; JSON with keys sorted, no insignificant whitespace, UTF-8. `selectorDigest = "sha256:" + hex(sha256(canonicalJson(selector)))`.

`params` v1 fields:
- `uplink`: `{ name: string, expectPermanentMac?: string }`
- `management`: `{ permanentMac: string }` (bridge precondition)
- `addressing`: `{ family: "ipv4", address, prefixLength, gateway? }`
- `datapath`: `{ tap: string, tapMac: string, bridge?: string, bridgeMac?: string, proxyArp?: bool, forward?: [string] }`
- `peer`: `{ kind: "vm", tap: string }`

`paramsDigest = "sha256:" + hex(sha256(canonicalJson(params)))` is computed by the applier and stored in state for idempotence; it is not in the marker.

Digest pinning: `profiles.json` embeds `allowedSelectors = { proxyarp = ["sha256:…"]; bridge = ["sha256:…"]; }` derived at evaluation from canonical selector objects in `profiles.nix`. No hand-written hex in Nix.

Example (`proxyarp`; synthetic values only):

```json
{
  "schema": "manilov.network.marker/v1",
  "profile": "proxyarp",
  "role": "owner",
  "owner": { "kind": "image", "id": "nikolaigogol" },
  "selectorDigest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
  "params": {
    "uplink": { "name": "wlan-test0", "expectPermanentMac": "02:00:00:00:00:04" },
    "management": { "permanentMac": "02:00:00:00:00:05" },
    "addressing": { "family": "ipv4", "address": "203.0.113.10", "prefixLength": 24, "gateway": "203.0.113.1" },
    "datapath": { "tap": "tap0", "tapMac": "02:00:00:00:00:06", "proxyArp": true, "forward": ["tap0", "wlan-test0"] },
    "peer": { "kind": "vm", "tap": "tap0" }
  }
}
```

The `bridge` example differs only in `profile="bridge"` and `datapath={ "bridge":"br0","bridgeMac":"02:00:00:00:00:07","tap":"tap0","tapMac":"02:00:00:00:00:08" }`.

Forward-compat: adding `role="consumer"` and the owner's `owner.id` requires no schema change. If the architect lands "N owners allowed", only `check`'s owner-uniqueness rule and the `consumer` code path change; `selectorDigest` and the `profiles.json` shape stay v1-compatible (additive fields only). The exact seam is `allowedSelectors` plus `check.owner-uniqueness` in §4.4.

### 4.4 Applier CLI and validation

Binary: `manilov-network`. `--version` prints `manilov-network 1.0.0 (image nikolaigogol)`.

```
manilov-network <check|apply|status|rollback|watchdog> [options]

Options:
  --marker PATH            default /etc/manilov/marker.json
  --state-dir PATH         default /var/lib/manilov-network
  --root PATH              test-only filesystem prefix
  --netlink-fixture PATH   test-only live-state snapshot
  --plan                   print the ordered op plan as JSON; no mutation
  --json                   machine-readable output
  --version
  --help
```

`check` (read-only, no mutation):
1. Marker readable and valid JSON (else 3).
2. `schema`, `profile`, `role`, `owner` shapes valid (else 8).
3. Recompute `selectorDigest`; must equal the field and be in `allowedSelectors[profile]` (else 3).
4. `owner.kind == "image"` and `owner.id == imageId` (else 4).
5. `params.uplink.name` exists, is up, and permanent MAC matches when given (else 5).
6. No conflicting datapath/L3 owner: bridge → `UPLINK` has no address/default route and any existing `br0` is ours; proxyarp → any existing `tap0` matches `tapMac`; any foreign owner marker in `/run/manilov/owners/` is a conflict (else 6).
7. Bridge only: `Unmanaged` drop-in matching `params.management.permanentMac` present in `hostNetworkdView` (else 7).
8. `role == "consumer"`: `check` validates read-only and exits 0; `apply`/`rollback` exit 12.

With `--json`, prints `{"ok":true,"profile":...,"checks":[...]}`.

`apply`:
- Runs `check` first; any nonzero exit aborts with the same code. If `role == "consumer"`, exit 12.
- Refuses a profile switch while state is `applied` with a different profile (exit 11; operator must `rollback` first).
- Computes `paramsDigest`; if state is `applied`, profile and digest match, and live state matches, it is a no-op (`changes: 0`).
- Otherwise applies the profile op list in order, writing `state.json` `phase="applying"` then `"applied"`.
- Idempotent: re-running `apply` after success never duplicates links, addresses, sysctls, or nft rules.

`status`: read-only; prints `status.json` (below). Exit 0 if `phase=applied` and live checks pass; 1 if degraded/not applied; 2 on unreadable marker.

`rollback`: idempotent; reverses ops in reverse order; deletes only `inet manilov_vm`; bridge writes `handoff={to:"host",reason:"manual|deadman|profile-switch"}`; never edits host files.

`watchdog`: runs `check`; on any failure runs `rollback` with `reason="deadman"` and exits nonzero. This is the image dead-man.

Exit-code table (stable contract):
- 0 success
- 2 usage
- 3 marker missing/unreadable/unknown selector digest
- 4 identity mismatch
- 5 uplink missing/ineligible
- 6 conflicting L3/datapath owner
- 7 host precondition missing
- 8 schema invalid
- 9 apply failed
- 10 rollback failed
- 11 profile switch requires rollback
- 12 write attempted by a consumer / unsupported role

### 4.5 systemd units and timer

- `manilov-network.service`: `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=… apply`, `ExecStop=… rollback`, `StateDirectory=manilov-network`, `RuntimeDirectory=manilov`, `After=network-pre.target`, `Before=network.target`, `WantedBy=multi-user.target`.
- `manilov-network-watchdog.service`: `Type=oneshot`, `ExecStart=… watchdog`.
- `manilov-network-watchdog.timer`: `OnBootSec=30s`, `OnUnitActiveSec=${watchdogInterval}`, `Unit=manilov-network-watchdog.service`, `Persistent=false`.
- If the image runtime is not systemd-as-PID1, the entrypoint must call `apply` and run the watchdog loop; the units remain the NixOS-system interface. Tests assert unit text/options, not live PID1 behavior.

### 4.6 Firewall split (normative)

- Image owns exactly one table: `inet manilov_vm`.
  - Base chain `forward` with `type filter hook forward priority 0; policy accept;` that jumps to `vm_path` only for `iifname/oifname { "br0", "tap0" }`.
  - `vm_path` contains only the VM-path accept/drop rules; it never sets a global `drop` policy.
- Forbidden: `flush ruleset`, editing/deleting `table inet filter`, touching `INPUT_PROTECT`, `DOCKER-*` chains, or any host-owned chain.
- `rollback` deletes only `table inet manilov_vm`.
- Test: `--plan` output lint asserts the only table name is `manilov_vm`, no `flush ruleset`, no `policy drop`, no `DOCKER-`.

### 4.7 Parity between `NikolaiGogol` and `NikolaiGogol_inner`

- Both systems import the same module path and must produce byte-identical `effective` JSON:
  `{ schemaVersion, imageId, applierVersion, profiles, allowedSelectors, nftTable, units }`.
- `NikolaiGogol_inner` keeps importing the module for the edge loop; it must not fork profile data.
- `checks.x86_64-linux.manilov-network-parity` evaluates both `config.services.manilov-network.effective` and diffs them; any difference fails.
- Also assert `config.services.manilov-network.modulePath` is the same string in both.

### 4.8 Fixtures (committed in `Unix_dotfiles`)

- `tests/fixtures/manilov/salt.json` — proxyarp, synthetic `wlan-test0`, RFC 5737 `203.0.113.0/24`, MACs `02:00:00:00:00:0x`.
- `tests/fixtures/manilov/terra.json` — bridge, synthetic `eth-test1`, RFC 5737 `198.51.100.0/24`, MACs `02:00:00:00:00:1x`.
- `tests/fixtures/manilov/bad-digest.json` — valid shape, wrong `selectorDigest`.
- `tests/fixtures/manilov/bad-schema.json` — unknown `schema` / missing `params`.
- `tests/fixtures/manilov/wrong-owner.json` — `owner.id != imageId`.
- `tests/fixtures/manilov/no-uplink.json` — `uplink.name` absent from the netlink fixture.
- `tests/fixtures/manilov/conflict-l3.json` — bridge with `UPLINK` still addressed.
- `tests/fixtures/manilov/missing-unmanaged/` — host-networkd view without the matching drop-in.
- `tests/fixtures/manilov/netlink/*.json` — recorded link/addr/route snapshots for the pure tests.

Rule: no real host values; only RFC 5737 addresses, `02:00:00:00:00:xx` MACs, and `*-test*` interface names.

### 4.9 Tests

**Tier 1 — sandbox-safe, no root/network**
- Schema/digest unit tests over all fixtures.
- `--plan` golden tests for `salt.json` and `terra.json` (ordered op lists).
- Fail-closed tests: bad digest → 3, wrong owner → 4, no uplink → 5, conflict → 6, missing unmanaged → 7, bad schema → 8, consumer → 12.
- Idempotence at the plan level: `plan(apply(state)) == []` when state matches.
- nft lint: only `manilov_vm`, no `flush ruleset`, no `DOCKER-`.
- No-host-literals grep over the module.
- Parity and single-image assertions.

**Tier 2 — network namespace, veth pairs; requires `unshare -Urn`**
- Create `veth-uplink` + peer; set synthetic MACs; run `check`/`apply`/`status`/`rollback` for `salt.json` and `terra.json`.
- Assert live objects: `tap0`, `proxy_arp`, `br0`, enslaved uplink, address move, nft table.
- Assert second `apply` is a no-op and `status --json` shows `changes: 0`.
- Assert `rollback` removes only image-owned objects and sets `handoff.to="host"`.
- Guard: if `unshare -Urn true` fails, exit 77 (skip) with a clear message; record as a stop condition, not a failure.

---

## 5. Interface contracts (bootstrap ↔ image)

### 5.1 Bootstrap must provide to the image

- Marker file at `/etc/manilov/marker.json`, read-only bind mount, exact v1 schema and pinned `selectorDigest`.
- Host networkd view at `/run/manilov/host-networkd/`, read-only bind mount of the host `/etc/systemd/network`, containing the `Unmanaged` drop-in with `[Match] PermanentMACAddress=<management permanent MAC>` and `[Network] Unmanaged=yes`, plus a `.bak.<timestamp>` backup on the host. Bridge `check` requires it; proxyarp ignores it.
- State directory `/var/lib/manilov-network/` as a persistent writable volume (root-owned), mounted before `manilov-network.service`.
- Host rescue timer + static address on the second NIC (bootstrap-owned; not implemented here). Its contract is to watch `state.json.phase` and remove the `Unmanaged` drop-in when the image reports `rolled-back`.
- No env var, hostname, or `/etc/hosts` entry is part of profile selection.

### 5.2 The image must provide back

- `state.json` (`manilov.network.state/v1`): `phase` (`absent|applying|applied|degraded|rolled-back`), `profile`, `role`, `owner`, `selectorDigest`, `paramsDigest`, `applierVersion`, `handoff`, timestamps.
- `status.json` (`manilov.network.status/v1`): live view + `checks[]`; refreshed by `status` and the watchdog.
- `check` exit codes as in §4.4, stable across versions of the same major.
- `apply` is idempotent; `rollback` is idempotent and never edits host files.
- `--plan` JSON so the bootstrap/host side can diff intent without applying.

### 5.3 Symmetric offline verification

- Both sides validate the same JSON schemas committed in `Unix_dotfiles` (`schema/*.json`).
- The harness verifies the image side only, using `--root` and `--netlink-fixture` against `tests/fixtures/host/`; no SSH, no Ansible, no live host.
- The bootstrap side (drop-in writer, rescue timer) is out of scope and is validated by the operator/other harness.

---

## 6. Completion criteria and exact commands

Run from the `Unix_dotfiles` flake root. Confirm output names with `nix flake show` first; the names below are expected.

**C1 — flake evaluates**
```bash
nix flake check --no-build --keep-going
```

**C2 — profile data and marker schema**
```bash
nix eval --json '.#dockerConfigurations.NikolaiGogol.config.services.manilov-network.profiles' \
  --apply 'p: builtins.attrNames p'
# expected: ["bridge","proxyarp"]

nix eval --json '.#dockerConfigurations.NikolaiGogol.config.services.manilov-network.effective' \
  --apply 'e: builtins.all (p: builtins.length p.ops > 0) (builtins.attrValues e.profiles)'
# expected: true

nix eval --json '.#dockerConfigurations.NikolaiGogol.config.services.manilov-network.effective' \
  --apply 'e: builtins.all (v: builtins.all (d: builtins.match "sha256:[0-9a-f]{64}" d != null) v) (builtins.attrValues e.allowedSelectors)'
# expected: true
```

**C3 — no build-time profile switch**
```bash
nix eval --json '.#dockerConfigurations.NikolaiGogol.config.services.manilov-network' \
  --apply 'c: !(c ? buildProfile) && !(c ? activeProfile) && !(c ? defaultProfile) && !(c ? mode)'
# expected: true
```

**C4 — no host-specific literals in the image**
```bash
nix build --no-link '.#checks.x86_64-linux.manilov-network-no-host-literals'
# fails on DEPLOY_HOST, terra-local, @terra, @salt, eth1, wlan0, real RFC1918 literals, real MACs
```

**C5 — schema, digest, plan, and fail-closed unit tests**
```bash
nix build --no-link '.#checks.x86_64-linux.manilov-network-pure'
# includes: salt.json/terra.json plans, bad-digest(3), wrong-owner(4), no-uplink(5),
# conflict-l3(6), missing-unmanaged(7), bad-schema(8), consumer(12), nft lint, idempotent plan
```

**C6 — parity**
```bash
nix build --no-link '.#checks.x86_64-linux.manilov-network-parity'
# or:
nix eval --json '.#dockerConfigurations.NikolaiGogol.config.services.manilov-network.effective' > /tmp/ng.json
nix eval --json '.#nixosConfigurations.NikolaiGogol_inner.config.services.manilov-network.effective' > /tmp/ngi.json
diff -u /tmp/ng.json /tmp/ngi.json
# expected: no diff
```

**C7 — both systems build**
```bash
nix build --no-link '.#dockerConfigurations.NikolaiGogol.config.system.build.toplevel'
nix build --no-link '.#nixosConfigurations.NikolaiGogol_inner.config.system.build.toplevel'
```

**C8 — one image for both profiles (content-tag stability)**
```bash
nix build --no-link --print-out-paths '.#dockerConfigurations.NikolaiGogol.config.system.build.toplevel'
# inspect the built system/image: /etc/manilov/profiles.json must contain both keys
# assert the image derivation takes no profile argument (C3); record the single content tag/digest
```

**C9 — applier integration in a network namespace (privileged tier)**
```bash
unshare -Urn true && echo netns-ok
nix develop .#manilov-netns --command bash tests/manilov/netns/run.sh
# expected: salt.json and terra.json pass check/apply/idempotence/rollback + fail-closed cases
# if `unshare -Urn true` fails: record skip (exit 77) and stop for a privileged environment
```

**C10 — applier CLI surface**
```bash
nix run .#manilov-network -- --help
nix run .#manilov-network -- --version
# help must show check/apply/status/rollback/watchdog and the exit-code contract
```

**C11 — rollback hands L3 back (bridge, netns tier)**
```bash
nix develop .#manilov-netns --command bash tests/manilov/netns/run.sh --case bridge-rollback
# expected: br0/tap0 gone, uplink up and unaddressed, state.json phase=rolled-back, handoff.to=host
```

---

## 7. Definition of done

- [ ] Shared module exists and is imported by both `NikolaiGogol` and `NikolaiGogol_inner`; no duplicated profile data.
- [ ] Options `services.manilov-network.*` implemented; forbidden build-time profile options absent.
- [ ] `profiles.nix` contains exactly `proxyarp` and `bridge`, both op lists non-empty, no host values.
- [ ] Marker v1 schema + canonical selector digest + allowlist implemented and tested.
- [ ] Applier implements `check`/`apply`/`status`/`rollback`/`watchdog` with the documented exit codes; `apply`/`rollback` idempotent.
- [ ] `manilov-network.service` + `manilov-network-watchdog.service` + `.timer` defined.
- [ ] nft table `inet manilov_vm` only; no host ruleset mutation; lint test passes.
- [ ] Bridge `check` requires the `Unmanaged` drop-in evidence; proxyarp does not.
- [ ] Bridge `rollback` hands L3 back and records `handoff.to="host"`.
- [ ] Fixtures `salt.json` / `terra.json` + fail-closed fixtures committed; no real host values.
- [ ] All C1–C11 pass locally (C9/C11 may be skipped only with exit 77 and a recorded reason).
- [ ] Parity: `effective` JSON identical for both systems.
- [ ] One image rebuild only; content tag/digest recorded.
- [ ] Handoff artifact (§9) filled in.

---

## 8. Stop conditions

Stop and ask if:
- A required `Unix_dotfiles` file or output name is missing or differs from this plan (`systems/.../default.nix`, `lib/modules/default.nix`, `dockerConfigurations.NikolaiGogol`, `nixosConfigurations.NikolaiGogol_inner`).
- System ownership is ambiguous: it is unclear whether a change belongs in `NikolaiGogol`, `NikolaiGogol_inner`, or the shared module.
- A required test needs root or network access the harness does not have (`unshare -Urn` unavailable, `nft`/`ip` missing, sandbox blocks netlink). Record exit 77 and stop; do not weaken the test.
- The architect's multi-container rule conflicts with D10 (e.g. N owners allowed, or `consumer` must be implemented in v1). Do not guess; return the conflict.
- The marker schema cannot express the host parameters without host-specific values leaking into Nix.
- A change would require editing the bootstrap repo, SSH, or `Virt_scripts_bootstrap`.
- `nix flake check` fails for reasons unrelated to this task; isolate and report, do not fix unrelated hosts.

---

## 9. Handoff format (what the harness returns)

Markdown report with:
1. Changed file paths (exact, repo-relative).
2. Option names and defaults actually implemented.
3. Marker schema (final JSON Schema path + example `salt.json`/`terra.json`).
4. `manilov-network --help` verbatim and `--version` output.
5. Test commands run + results (C1–C11), including skipped tiers and why.
6. Content tag/digest of the single rebuilt image.
7. Parity evidence (`effective` JSON diff or "identical").
8. Open questions / deviations from this plan.

No SSH, no Ansible, no `@terra`/`@salt` claims. State explicitly: "verified locally in `Unix_dotfiles`; no live-host verification performed."

---

## 10. Traceability (findings → plan)

| Finding | Where encoded |
|---|---|
| F1 = C′ ownership split | §3 D5/D6, §4.2, §4.6, §5.1 |
| F3 one host-independent image | §3 D2/D3, §4.1 forbidden options, C3/C8 |
| F4 durable vs edge fork | §4.7, C6 |
| Mode selection | §3 D3/D4, §4.3, §4.4 |
| Applier | §4.4, C5/C9/C10 |
| Firewall split | §4.6, C5 |
| Host relinquish | §4.2 bridge, §4.4 step 7, §5.1 |
| Rescue | §3 D9, §4.4 rollback/watchdog, §5.1 |
| Multi-container | §3 D10, §4.3 forward-compat |

---

## 11. Assumptions / open questions

- Output attr names assumed as `dockerConfigurations.NikolaiGogol` and `nixosConfigurations.NikolaiGogol_inner`; confirm with `nix flake show`.
- The repo's image builder/tag output name is not restated here; the harness records it.
- The architect's multi-container rule is **resolved** by ADR 0007: exactly one datapath owner per host; any number of consumers. D10 is aligned. If the rule changes, only §4.3 forward-compat and §4.4 step 6 change.
- `proxyarp` needs a pinned `tapMac` for the MAC pin; the bootstrap must supply it in `params.datapath.tapMac`.
- `bridge` needs `params.datapath.bridgeMac` for the MAC pin; the bootstrap must supply it.
