# Analyst handoff — Logseq journal entry for 2026-09-27 (NikolaiGogol deployment plan)

> Scratch handoff. This is **not** repository documentation. It exists so a
> **directly-invoked** `@analyst` (top-level session, where the `logseq-analyst*`
> MCP tools bind) can publish the note to Logseq. Safe to delete after publishing.

## Task for the analyst

Publish the content below to Logseq, following the normal analyst → `analyst-kbn`
journaling workflow:

- **Dedicated page:** `ai-anl Analyst_system/NikolaiGogol deployment plan — planning session complete`
- **Journal entry:** `ai-anl Analyst_system/_journals/2026-09-27` → `Updated [[ai-anl Analyst_system/NikolaiGogol deployment plan — planning session complete]]` + simplified copy
- **Planner publish:** `ai-pln Planner_system/NikolaiGogol deployment plan`

Do **not** modify the code repository. A nested analyst session could not bind the
Logseq MCP tools (harness issue); this handoff is the workaround.

---

## Content to publish

**Title:** NikolaiGogol deployment plan — planning session complete

A Builder/Planner session completed and the user approved an implementation plan
for syncing the NixOS system-container image from the local workstation to
`@terra` (TOS 6) and deploying it as the `@NikolaiGogol` privileged systemd
container, idempotently, with a two-speed iteration model (fast edge-iterate,
then full idempotent chain redeploy).

**Artifact (reference, do not copy):**
`docs/HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment_plan.md` in
`PersonalLentServers%Russian_dotfiles.bootstrap` — page reference
`[[HomeServer__StratoFrame__ConvPlatProv__NikolaiGogolDeployment plan]]`
(title: "Plan — Sync the NixOS image (local → `@terra`) and deploy the `@NikolaiGogol` system container").

**Repos involved (all under `.../ChronoIndex/2026/`):**
- `PersonalLentServers%Russian_dotfiles.bootstrap` — target Ansible bootstrap repo (Layer 0 done; plan adds Layer 1 `@NikolaiGogol`).
- `ConvPlatProv-HomeServer__HomeAssistant/@NikolaiGogol` — source of truth for the current manual container flow.
- `ConvPlatProv-HomeServer__HomeAssistant/docker-nixos` — skiffos-based NixOS image build reference.
- `~/.bookmarks/shared-configs/Unix_dotfiles` — `NikolaiGogol` host config + build target (`make build-NikolaiGogol` → `result-NikolaiGogol/tarball/nixos-system-x86_64-linux.tar.xz`).
- `@tangerineDream` — aspirational parity reference; explicitly out of scope.

**Key decisions (one line each):**
- Scope: full path — image sync + container deploy + documented edge-iteration; container changes via editing `Unix_dotfiles` `NikolaiGogol` config + rebuild; edge-sync helpers optional/adhoc.
- Image identity: content-addressable tag `ds-omega/nikolai-gogol:<sha12>` (first 12 hex of the rootfs tar.xz sha256).
- Transfer: `ansible.posix.synchronize` (rsync `--checksum`).
- Reach `@NikolaiGogol`: direct SSH (ProxyJump or port 2223) primary for auto Ansible deploy; `ssh @terra && docker exec -it …` stays for ad-hoc debugging.
- Decomposition: 4 roles (`nixos_image_artifact`, `nixos_image_sync`, `nixos_image_load`, `nixos_container`) + `deploy-nikolaigogol.yml` + `verify-nikolaigogol.yml`; tags `image`/`container`; full four-layer test coverage (unit/integration/E2E/manual).

**Undecided — Layer 2 `@Manilov` (HAOS VM):** NOT planned yet (roadmap playbook `deploy-manilov.yml`). Open threads to pick up in a future session:
- `@NikolaiGogol` system-container compose bind-mounts `${HOME_ASSISTANT_IMAGE}` → `/opt/HomeServer__HomeAssistant/haos_ova.qcow2`; an `haos_ova-16.3.vdi.zip` artifact exists in `ConvPlatProv-HomeServer__HomeAssistant/` → HAOS disk image likely staged/synced alongside the NixOS image (reuse the rsync + content-addressable pattern).
- `group_vars/manilov/vars.yml` placeholder: `manilov_vm_name: "hass_qemu16"`, `manilov_data_dir: "/mnt/data"`.
- Per `docs/Deploy#NixContainer.puml` + ADR 0001: `@Manilov` is hosted by `@NikolaiGogol` via libvirt/VirtualBox; USB/Zigbee passthrough chain (UsbZigbeeDocker → UsbZigbeeVm); "no nested virtualization" for external docker services; HomeAssistant config partly Nix (NixOS HomeAssistant module + custom integrations/addons) and partly hoisted config volumes from `@terra` ("Config Sync" / "Ha_config mount").
- User: HomeAssistant inside `@NikolaiGogol` "may require changes to the configurations too" → the direct-SSH / docker-exec edge-iteration affordances must extend to HA configs.
