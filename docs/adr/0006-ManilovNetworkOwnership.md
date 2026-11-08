# ADR 0006 — `@Manilov` network ownership: image-owned datapath, host-owned transport

- **Status:** Accepted (2026.11.02) — operator decisions recorded in §6a
- **Task:** `MANILOV-MVP-001`
- **Target:** `@Manilov` (VM), hosted by `@NikolaiGogol` (NixOS system container)
- **Hosts:** `@terra` (TOS 6, bridge mode), `@salt` (NixOS, Wi-Fi proxyARP mode)
- **Repos in scope:** `PersonalLentServers%Russian_dotfiles.bootstrap`,
  `Unix_dotfiles` (`systems/x86_64-docker/NikolaiGogol`,
  `systems/x86_64-linux/NikolaiGogol_inner`),
  `ConvPlatProv-HomeServer__HomeAssistant/Virt_scripts_bootstrap`
- **Supersedes:** the host-side bridge/dead-man/persist ownership proposed by the
  `MANILOV-MVP-001` MVP plan (see §8). It does not supersede ADR 0001–0005;
  it refines ADR 0001 §2 (per-layer playbooks) at the network boundary.
- **Revision:** 2 (2026.11.02). Standardizes the `manilov-network` names,
  records the operator's answers to §6, and withdraws the §6 Q3 fallback
  ("the host pre-adds the subnet"). F1 = C′, F3, F4, D4 and D7 are unchanged.
- **Evidence:** `docs/NetworkTopology__@terra__@Manilov.md`,
  `docs/NetworkTopology__@salt__@Manilov.md`,
  Logseq `ai-rsh Researcher_system/MANILOV-MVP-001 @terra network research (2026.11.02)`,
  raw probe `logs/network-research-20261102T164715Z/` (git-ignored).
- **Decision owner:** operator. **Reviewer:** not set (`reviewed-by` is never
  set by the architect).

## 1. Context

`@Manilov` is a Home Assistant OS VM run by libvirt inside the `@NikolaiGogol`
system container. The container runs with `network_mode: host` and
`privileged: true`, so anything the image's NixOS networking configures lands in
the *host* network namespace. That is how `@salt` already works today:
`Unix_dotfiles/systems/x86_64-linux/NikolaiGogol_inner/default.nix` declares
`tap0`, `proxyARP` on `tap0` and `wlan0`, IPv4 forwarding, and FORWARD rules;
`qemu.runAsRoot = true` lets libvirt attach the tap.

On `@terra` the same boundary collides with a pre-existing owner:

- `systemd-networkd` owns L3 on `eth1` via per-MAC
  `/etc/systemd/network/10-eth*.network` (`ClientIdentifier=mac`), and reasserts
  DHCP on every carrier event and reboot.
- The host nftables `FORWARD` policy is `drop`, `br_netfilter` is built in with
  `bridge-nf-call-* = 1`, and Docker owns `DOCKER-*` chains.
- `INPUT_PROTECT` accepts SSH (port 9222) only from the management subnet and
  gateway; anything else is dropped.
- `eth0` has no carrier; `eth1` is the only connected NIC.

The operator resolved the ownership fork:

> "C' — image should own `br0` and all other network configurations that are
> crucial for `@NikolaiGogol` and `@Manilov` operations. Host network is used
> only for global configurations (in case we had, for instance, other docker
> containers like `@NikolaiGogol` or global firewall) and `@terra`–`@salt`
> connection (ssh, for example)."

and the F4 fork:

> "`NikolaiGogol_inner` is about edge rebuild … But it could be easily
> transferred into `NikolaiGogol`. It doesn't change much apart from deployment:
> both represent the same system. Treat inner system like a 'fork' of a former
> system."

So this ADR must make two things true at once: **the image is the single writer
of the `@Manilov` datapath**, and **the host remains the single writer of
everything the image must not break** — the global firewall, SSH, and the
`@terra`–`@salt` transport.

## 2. Decision drivers

1. One datapath writer per surface; no two writers may race on the same link,
   address, MAC, or nftables chain.
2. One host-independent image; no per-host image fork.
3. Fail closed and loudly if the selected mode contradicts the host.
4. Reboot/recreate survivability: the VM path must return without manual `ip` or
   `nft` commands.
5. SSH must survive the L3 move; losing remote access is the worst failure mode.
6. The host must keep a rescue path that does not depend on the image or the
   container being healthy.
7. The strategy schema stays about deployment, not about host topology.

## 3. Decision

### D1 — C′ ownership boundary (F1)

| Surface | Owner | Contract |
|---|---|---|
| Network **mode** declaration | host provisioning (bootstrap), read-only to image | a pinned, hashed marker file; the image never infers the mode from `DEPLOY_HOST`, `/etc/hosts`, hostname, or an env var |
| `br0` creation, uplink enslavement, L3 move, MAC pin | image applier (`bridge` profile) | the image is the only writer after the host relinquishes the uplink |
| `tap0`, `proxyARP`, IPv4 forwarding, tap↔uplink rules | image applier (`proxyarp` profile) | same applier, different immutable profile |
| VM-path FORWARD rules | image applier | dedicated nftables table/chain only; never `flush ruleset`; never touch `DOCKER-*`, the host `filter` table, or `INPUT_PROTECT` |
| VM tap attachment (libvirt interface element) | image applier, rendered from the selected profile | `type='bridge'` + `source bridge='br0'` for bridge; `type='ethernet'` + `target dev='tap0' managed='no'` for proxyARP |
| Global firewall policy and rules | host (TOS nftables; host NixOS on `@salt`) | the image adds only its own table/chain and must not change the host policy |
| SSH listener and `INPUT_PROTECT` | host | the image must never edit them; the host adds subnets only as an explicit precondition |
| Host uplink **relinquish** | host bootstrap (one-time, idempotent, backed up) | writes `Unmanaged=yes`; it is a hand-off, not a datapath writer |
| Host rescue (timer + static address on `eth0`) | host bootstrap | bounded safety net; no VM-path packets |
| Marker data | host provisioning | provisioned at deploy; bind-mounted read-only; digest pinned in the image |
| Active applier state | image applier | dedicated state dir; host rescue state is separate |

The host relinquish is the only host-side network *write*. It is deliberately
negative — it removes the host from the uplink so the image can own it. It does
not create `br0`, move L3, or write forwarding rules.

### D1.1 — Ownership summary

| Surface | Owner |
|---|---|
| Network mode declaration | host provisioning → pinned, hashed marker (read-only to the image) |
| `br0`, uplink enslavement, L3 move, MAC pin | `@NikolaiGogol` image applier (`bridge` profile) |
| `tap0`, proxyARP, forwarding, tap↔uplink rules | image applier (`proxyarp` profile) |
| VM-path FORWARD rules | image applier, dedicated table/chain only |
| VM tap attachment | image applier, rendered from the selected profile |
| Global firewall, SSH/`INPUT_PROTECT` | host |
| Host uplink **relinquish** | bootstrap repo (one-time, idempotent, backed up) — `Unmanaged=yes` drop-in on the existing `.network` file that matches the management NIC |
| Host rescue (`eth0` + timer) | bootstrap repo, safety net only |
| Dead-man / rollback | image applier's `rollback`, not a host script |

The host relinquish is the only host-side network *write*; it is a
negative/hand-off write — it removes the host from the uplink and hands the link
to the image — and never creates `br0`, moves L3, or writes forwarding rules.
The bootstrap repo is therefore not a datapath writer and must never be listed
as one.

**State directory and file names.** The network unit's own artifacts are
`/run/manilov-network/owner.lock` (per boot) and
`/var/lib/manilov-network/` (`owner.json` plus `state.json`, durable); the
host-provisioned marker stays `/etc/manilov/marker.json`. The short form
`manilov-net` is retired. ADR 0007 D3a carries the full name table.

The limit on how many `@NikolaiGogol`-like containers may own the datapath on
`@terra` is a separate decision: see ADR 0007
(`docs/adr/0007-ContainerDatapathOwnership.md`).

### D2 — Mode selection by pinned marker

The applier takes exactly one of two immutable profiles, selected by a marker
JSON file (bind-mounted read-only, hashed). The marker's allowed digests are
pinned into the image, so one image serves both hosts and an unknown or edited
marker fails closed. The marker is the *only* selector; `DEPLOY_HOST` remains a
deployment-target variable and must never choose the network mode.

**F3 (confirmed):** "without changing image contents" means one image with no
per-host fork; one rebuild to add the network module is acceptable. This permits
step 5 of §9 (rebuild **one** image and keep the previous content tag for
rollback). It does not permit per-host image forks or runtime injection of the
module.

The applier exposes one verb set: `check`, `apply`, `confirm`, `status`,
`rollback`, `watchdog`.

- `check` validates marker digest, profile, host identity, and preconditions
  (uplink present, no conflicting L3 owner, resulting management path consistent
  with `params.addressing`). It does **not** require the host to pre-authorize a
  subnet in `INPUT_PROTECT`: a wrong subnet is caught by the unconfirmed apply
  and fixed by rollback (§6a.3). It is read-only.
- `apply` is idempotent and writes only the surfaces in the right-hand column
  above.
- `confirm` records operator acknowledgement of an L3 move (`bridge` only). It
  is issued from the resulting management address; without it inside the bounded
  window the apply auto-reverts (D5).
- `status` reports drift and conflicts, including a host reasserting the uplink.
- `rollback` restores the previous active state (for the bridge profile this
  must include handing L3 back to the host, not just deleting `br0`).
- `watchdog` runs `check` and invokes `rollback` with `reason="deadman"` on
  failure; it is the in-image dead-man (D5).

### D3 — Host relinquish of the uplink

On `@terra`, the bootstrap repo (Layer 0) writes a drop-in that sets
`Unmanaged=yes` on the networkd `.network` file that currently matches the
management NIC. The drop-in is attached to the *existing* file discovered by
matching the NIC's permanent MAC, not to a hard-coded `10-eth1.network`.

- **Who:** `PersonalLentServers%Russian_dotfiles.bootstrap` — `@terra` is
  TOS 6 with only Nix home-manager, so there is no NixOS host system layer to
  own this write (see §6a.1).
- **When:** as an explicit, separate step before the first `bridge` apply;
  never inside a normal container deploy.
- **Backup:** copy `/etc/systemd/network` to a timestamped archive and record the
  exact drop-in path plus its hash in the host state file before writing.
- **Restore:** delete the drop-in, `networkctl reload`, and verify the uplink
  regains its address; the archive is the fallback.
- **Idempotent:** re-running the step is a no-op when the recorded drop-in path
  and hash already match; it never writes a second drop-in or a second archive.
- **Guard:** after relinquish, the host must not re-add a default route on the
  uplink. The applier's `status` reports a host reassertion; the host rescue
  remains available but does not repair the datapath.

### D4 — Firewall split

The host keeps the global firewall (policy, `INPUT_PROTECT`, Docker chains). The
image owns only a dedicated table/chain for the VM path, matching the managed
interfaces, with no `policy drop` and no flush. When the image chain returns,
the host policy still applies to everything outside the VM path. This preserves
F1 ("host … global firewall") and keeps Docker and SSH out of the image's blast
radius.

### D5 — Dead-man and host rescue

The host rescue is a safety net, not a datapath owner: a timer plus a static
address on the unconnected `eth0`, so an operator can regain a foothold if the
image, the container, or the bridge is broken. It belongs to the bootstrap repo,
because it must survive the image and cannot live inside the system it guards.
It must never add routes or addresses on the management uplink, never touch the
VM path, and never fight the applier.

The dead-man behaviour (revert on failed apply) belongs to the image applier's
`rollback`, not to a host script.

**Dead-man mechanics (2026.11.02).** The operator chose the simplest variant: no
host-side pre-authorization of a subnet, and the applier's `rollback` is the
dead-man.

- A `bridge` apply that moves L3 leaves the unit in `unconfirmed` until a
  `confirm` is recorded from the resulting management address. If no `confirm`
  arrives inside the bounded window, `rollback` runs with `reason="deadman"`.
- Confirmation can only arrive when the operator can reach the new address, so a
  subnet that `INPUT_PROTECT` does not cover produces exactly the intended
  outcome: no confirmation, automatic revert.
- Rollback records `phase="rolled-back"` and `handoff.to="host"`. The bootstrap
  rescue timer then restores the relinquished `.network` file (the reverse of
  D3's restore), so `systemd-networkd` reclaims the uplink without an operator
  touching the machine. That restore is bounded: it acts only when the state
  says `rolled-back` and the applier no longer owns the datapath.
- `proxyarp` needs no confirmation window: it moves no L3 and removes no host
  address.

### D6 — F4: durable system vs edge fork

`NikolaiGogol` (`systems/x86_64-docker/NikolaiGogol`) is the durable image
system. `NikolaiGogol_inner` (`systems/x86_64-linux/NikolaiGogol_inner`) is an
edge-rebuild fork of the same system, used only for the fast loop. The network
module moves out of `_inner` into a shared module imported by both; `_inner`
keeps importing it, so the edge loop is preserved without owning the contract.

Parity is a build-time check (both configurations evaluate to the same network
module output for the same marker fixture) plus a runtime `check` on each host.

### D7 — No `network` strategy field

The deployment strategy schema keeps exactly `name`, `executor`, `workspace`,
`env`, `compose`, `privilege`, `artifact`, `identity`, `paths`, `ownership`,
`pins`. Network mode is an L0 domain concern and lives in the marker, not in the
strategy. Verbs must not read a `network` field, and no strategy value may select
a profile.

## 4. Topology and event order

```text
@terra (bridge)                                   @salt (proxyARP)
────────────────────────────────                  ─────────────────────────────
LAN ── eth1 ══ br0 (L3, MAC = uplink perm MAC)     Wi-Fi AP ── wlan0 (L3, host MAC)
                    │                                             │ proxyARP + forward
                    └── libvirt tap ── @Manilov virtio            └── tap0 ── @Manilov virtio
```

```text
apply order (bridge):  marker check → uplink unmanaged (host, precondition)
                       → create br0 → enslave uplink → move L3/MAC
                       → attach VM tap → VM-path rules → verify
                       → state=unconfirmed → confirm | dead-man rollback
apply order (proxyARP): marker check → tap0 → proxyARP/forwarding
                       → attach VM tap → tap↔uplink rules → verify → record state
rollback:               reverse the recorded state; bridge rollback hands L3 back
```

## 5. Consequences

- One image, two profiles, one applier; no per-host image fork and no
  `DEPLOY_HOST`-based mode selection.
- A host-side relinquish becomes an explicit, auditable, reversible step; a
  failed bridge apply is recoverable without reinstalling TOS.
- The image cannot break Docker or SSH by construction: it has no write path to
  their tables or to `INPUT_PROTECT`.
- The host rescue survives a broken container; conversely it cannot repair the
  VM path, so a broken apply must be fixed through the applier.
- The strategy schema stays deployment-only.
- Two writers remain, but on disjoint surfaces: host transport/rescue vs image
  datapath. The `status` verb is the tripwire if that separation regresses.
- A wrong `INPUT_PROTECT` subnet no longer needs a host pre-write: the
  unconfirmed apply auto-reverts and the rescue restores host ownership.
- `_inner` remains a supported edge fork; the durable system becomes the source
  of the network contract.

## 6. Open questions (recommendation + alternative consequence)

All four are resolved by the operator on 2026.11.02; the verbatim answers are in
§6a. The recommendations below are kept for context, except where marked
withdrawn.

1. **Who writes the `Unmanaged` drop-in?** Recommended: the bootstrap repo
   (TOS 6 has no NixOS host layer). Alternative — host NixOS config — is not
   applicable on `@terra` and would create a second host-config owner.
   **Resolved (see §6a.1).**
2. **Global firewall vs VM-path FORWARD rules.** Recommended: split as D4.
   Alternative — image owns all firewall — violates single-writer and risks
   Docker/SSH lockout. **Resolved (see §6a.2).**
3. **`INPUT_PROTECT` if `br0` lands in a different subnet.** **Resolved — see
   §6a.3.** Pinning the uplink MAC keeps the host's DHCP client identity, which
   normally returns the same lease in place; the earlier fallback ("the *host*
   pre-adds the new subnet/gateway to `INPUT_PROTECT` before the apply") is
   **withdrawn**. The operator chose the dead-man variant: a wrong subnet is a
   rollback-and-fix (D5), and the host rescue is the recovery lever. The
   alternative — image edits `INPUT_PROTECT` — remains rejected: it violates D1
   and can lock out SSH.
4. **Same marker path on `@salt`?** Recommended: same path and schema, different
   content (`proxyarp`). Alternative — per-host path — forks the contract and
   invites inference from hostname. **Resolved (see §6a.4).**

## 6a. Resolved open questions (operator, 2026.11.02)

The operator's decisions are quoted verbatim; the surrounding text records only
their architectural consequences.

**0. Naming.** "Prefer manilov-network". Service units, the binary, the module,
the runtime directory and the state directory all use the full name; the short
form `manilov-net` is retired (D1.1, ADR 0007 D3a).

**1. Who writes the `Unmanaged` drop-in?**

> "bootstrap repo because terra host has only Nix home-manager."

Confirmed reason: `@terra` is TOS 6 with only Nix home-manager — there is no
NixOS host system layer, so "host NixOS config" is not an available owner on
that host. The drop-in writer therefore lives in the bootstrap repo (one-time,
idempotent, backed up). This remains a **negative/hand-off write**: it removes
the host from the uplink and hands the link to the image. It is not a datapath
writer and never creates `br0`, moves L3, or writes forwarding rules (D1.1, D3).

**2. Global firewall vs VM-path FORWARD rules.**

> "accept"

D4 stands unchanged: the host keeps the global policy, `INPUT_PROTECT` and the
`DOCKER-*` chains; the image owns one dedicated VM-path table/chain.

**3. `INPUT_PROTECT` if `br0` lands in a different subnet.**

> "I'm not sure about that. I would take simplest variant with dead-man
> rollback. What is `uplink MAC` in this context? If it's mac of a terra's device
> - ok. If it's MAC os salt's device - then no, @terra would be transported to
> another house with another router. Hence why all the fuss with arp vs bridge."

Answer to the question: **`uplink MAC` is the permanent MAC of the local host's
own physical NIC that carries the uplink** — on `@terra` that is `@terra`'s own
Ethernet NIC; on `@salt` it is `@salt`'s own Wi-Fi device. It is never the MAC
of the router, the gateway, a peer host, or the `@salt` device when the applier
runs on `@terra`. It is discovered at deploy time from the interface that
currently carries the management address (`systemd-networkd` / sysfs), never
hardcoded, and it is recorded in the marker only as an observed value and a
digest input — never as a selector.

Consequences:

- **The MAC pin is local, not upstream.** Pinning the uplink MAC keeps the
  host's DHCP client identity (`ClientIdentifier=mac`) and its L2 identity. It
  does not encode, and must not encode, which router or DHCP server answers.
- **Withdrawn:** the earlier fallback "the *host* pre-adds the new
  subnet/gateway to `INPUT_PROTECT` before the apply". The operator chose the
  simplest variant with a dead-man rollback: no host-side pre-authorization of a
  subnet.
- **A wrong subnet is a rollback-and-fix**, not a host pre-authorization. The
  bridge apply stays `unconfirmed` until the operator confirms it from the
  resulting management address. If that address is not reachable — because
  `INPUT_PROTECT` does not cover the new subnet — no confirmation arrives, the
  bounded timer fires, the applier's `rollback` runs, the state becomes
  `rolled-back`, and the bootstrap rescue restores the host `.network` file
  (D5). The recovery lever is the host rescue path (timer plus a static address
  on the unconnected `eth0`), not a firewall pre-write.
- **Moving `@terra` to another house with another router must not change
  `selectorDigest`, must not require an image rebuild, and must not require a new
  marker schema.** Only `params` and the upstream L2/DHCP environment change.
  That is exactly why `bridge` is the right profile on `@terra` (`br0` is
  L2-local and reaches whatever router sits on the uplink) and why `proxyarp`
  exists only for `@salt`, where the uplink is Wi-Fi and cannot be bridged.

**4. Same marker path on `@salt`?**

> "accept"

Same marker path and schema on both hosts, different content: `proxyarp` on
`@salt`, `bridge` on `@terra`. A per-host path is rejected — it forks the
contract and invites inference from hostname.

## 7. Alternatives considered

1. **Host-side `scripts/manilov/bridge-*.sh` owns the datapath** (the MVP plan's
   current shape). Rejected by F1: it is a second datapath writer, it does not
   survive image changes cleanly, and it duplicates the `@salt` logic that
   already lives in the image.
2. **Per-host image fork.** Rejected: breaks content-addressed identity (ADR
   0002) and doubles the verification surface.
3. **`DEPLOY_HOST`/hostname/env selects the mode.** Rejected: the same host can
   be reached by different names, and the mode is a property of the host, not of
   the deploy invocation.
4. **Image owns the whole firewall.** Rejected: collides with Docker and
   `INPUT_PROTECT`; a bad rule can cut SSH.
5. **No host rescue.** Rejected: a failed bridge apply could leave no remote
   path.

## 8. Supersession (MVP plan sections that must change)

The MVP plan lives in the restricted Orchestrator namespace; section titles are
cited from the task brief, line numbers are unavailable to this role.

- **Host-side `scripts/manilov/bridge-*.sh` — bridge ownership:** removed as a
  datapath writer; retained only if needed as a thin wrapper that calls the
  image applier's verbs.
- **Host-side `scripts/manilov/bridge-*.sh` — dead-man:** superseded by the
  applier `rollback`; no host dead-man script.
- **Host-side `scripts/manilov/bridge-*.sh` — persist:** superseded by the
  applier's boot-time `apply`/`status`; no host persistence script.
- **Mode selector:** superseded by the pinned, hashed marker; the plan's
  selector (including any `DEPLOY_HOST`-based branch) is withdrawn.
- **`DEPLOY_HOST`-based selection:** withdrawn everywhere; `DEPLOY_HOST` remains
  a deployment target only (consistent with `docs/StratoFrame__DeploymentPractices.md` §2).

No other plan section is superseded; image sync, container deploy, dependency
pins, and dirty-target protection are unaffected.

## 9. Migration sequence (contract level)

1. Extract the network + libvirt blocks from
   `systems/x86_64-linux/NikolaiGogol_inner/default.nix` into a shared module
   with two profiles.
2. Import the shared module from `systems/x86_64-docker/NikolaiGogol` (durable)
   and from `NikolaiGogol_inner` (edge fork); remove the duplicated blocks.
3. Add the marker contract (path, schema, allowed digests) and the
   `check`/`apply`/`confirm`/`status`/`rollback`/`watchdog` verbs.
4. Add the parity check: both configurations evaluate to identical module output
   for the same marker fixture.
5. Rebuild **one** image from the durable system; keep the previous content tag
   for rollback.
6. Verify `proxyarp` first (no host relinquish, lowest risk), then perform the
   `@terra` relinquish and verify `bridge`; run `status` after a container
   recreate and after a reboot.
7. Only then remove the old host-side bridge scripts from the plan/repo.

## 10. Validation gates

- `check` fails closed on unknown marker digest, wrong host identity, missing
  uplink, or a conflicting L3 owner.
- After `bridge` apply: `br0` owns the address and default route, MAC equals the
  uplink permanent MAC, the VM tap is enslaved, and `arping` from the LAN gets
  the bridge MAC.
- SSH on 9222 still works from the management subnet after the L3 move.
- `nft list ruleset` shows the image table/chain and an unchanged host policy,
  `INPUT_PROTECT`, and `DOCKER-*` chains.
- `status` is clean after container recreate and after reboot.
- Host rescue: the timer fires and the `eth0` address is reachable without
  touching the uplink.
- `proxyarp` and `bridge` both pass from the same image content tag.
- An unconfirmed `bridge` apply auto-reverts inside the window and leaves
  `phase=rolled-back` and `handoff.to="host"`; the rescue then restores the host
  `.network` file and the management address returns.
- The unit's state lives at `/run/manilov-network/owner.lock` and
  `/var/lib/manilov-network/{owner.json,state.json}`; no `manilov-net` path
  exists anywhere.

## 11. Rollback

- Image: re-run the previous content tag (ADR 0002) and `rollback` the applier.
- Bridge: `rollback` removes the VM-path rules and the tap attachment, deletes
  `br0`, and hands L3 back to the host; then remove the `Unmanaged` drop-in and
  `networkctl reload`.
- Host: restore the `/etc/systemd/network` archive if the drop-in restore fails.
- The host rescue remains the last resort and is independent of all of the
  above.

## 12. Prohibited changes

- The image must not flush or rewrite the host `filter` table, `DOCKER-*`
  chains, or `INPUT_PROTECT`.
- The image must not infer the mode from `DEPLOY_HOST`, hostname, `/etc/hosts`,
  or an environment variable.
- The host bootstrap must not create `br0`, move L3, or write VM-path rules.
- No per-host image fork; no `network` field in the strategy schema.
- The host rescue must not touch the management uplink or the VM path.
- The marker must never select on the upstream router, gateway, or DHCP server
  identity: no router MAC, no DHCP server address, and no house-specific subnet
  in `selectorDigest`.
- The host must not pre-add a predicted subnet to `INPUT_PROTECT` as a
  precondition of the bridge apply; a wrong subnet is a rollback-and-fix (§6a.3).

## 13. References

- `docs/NetworkTopology__@terra__@Manilov.md`
- `docs/NetworkTopology__@salt__@Manilov.md`
- `docs/adr/0001-HomeServer__HomeAssistant.md` (layered model)
- `docs/adr/0002-ContentAddressableImageTag.md` (one image identity)
- `docs/adr/0007-ContainerDatapathOwnership.md` (one datapath owner per host)
- `docs/StratoFrame__DeploymentPractices.md` §1–§2 (surfaces, `DEPLOY_HOST`)
- `Unix_dotfiles/systems/x86_64-linux/NikolaiGogol_inner/default.nix`
- `Unix_dotfiles/systems/x86_64-docker/NikolaiGogol/default.nix`
- `ConvPlatProv-HomeServer__HomeAssistant/Virt_scripts_bootstrap/vmDefinition.xml`
