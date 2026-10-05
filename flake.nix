{
  description = "PersonalLentServers%Russian_dotfiles.bootstrap — pinned dev shell for the Ansible bootstrap tooling";

  # Pinned to a concrete nixos-26.05 channel revision (bcc4a9d = 2026-02-18).
  # 26.05 is a Hydra-built release branch, so every runtime dependency below
  # substitutes from cache.nixos.org. `flake.lock` records the exact rev/narHash;
  # bump deliberately with `nix flake update`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/bcc4a9d9533c033d806a46b37dc444f9b0da49dd";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          # The Ansible *community distribution* (13.3.0): a pinned,
          # content-addressed source that bundles the ansible.posix and
          # community.docker collections under
          # lib/python3.13/site-packages/ansible_collections/.
          #
          # We use it only as the collection source (not for executables — the
          # wheel deliberately drops its ansible-core dependency, so the
          # ansible-* commands come from the `ansible-core` below). In this
          # nixpkgs rev `ansible-core` already depends on this distribution
          # (pkgs/development/python-modules/ansible/core.nix), so the
          # collections arrive with the interpreter anyway; ANSIBLE_COLLECTIONS_PATH
          # is set explicitly below so the source is intentional and documented
          # rather than relying on that transitive wiring. Either way it is a
          # Nix derivation — no network `ansible-galaxy install` on shell entry.
          ansibleCollections = pkgs.python3Packages.ansible;

          # One Python 3.13 environment for the unit tests (pytest/PyYAML/Jinja2)
          # and for the ansible-core executables.
          python = pkgs.python3.withPackages (ps: with ps; [
            pytest
            pyyaml
            jinja2
            ansible-core
          ]);
        in
        {
          default = pkgs.mkShell {
            name = "personal-lent-servers-bootstrap";

            packages = [
              python
              pkgs.ansible-lint
              pkgs.rsync # convenience: ansible.posix.synchronize needs it at runtime
              pkgs.git # ansible-lint / ansible-galaxy need git to resolve role deps
            ];

            env = {
              # A colon-separated list of directories, each containing an
              # `ansible_collections/` tree. The community wheel's site-packages
              # holds exactly that, so point Ansible there.
              ANSIBLE_COLLECTIONS_PATH = "${ansibleCollections}/${pkgs.python3.sitePackages}";
            };

            shellHook = ''
              # Only banner on an interactive shell so `nix develop --command`
              # output stays clean for scripts/agents.
              if [ -t 1 ]; then
                echo "dev shell: $(python3 --version 2>&1), $(ansible --version 2>/dev/null | head -n1)"
                echo "available: make unit | make check | make lint   (docker: make it-* is not provided by this shell)"
              fi
            '';
          };
        }
      );
    };
}
