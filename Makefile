ifneq (,$(wildcard ./.env.dev))
    include .env.dev
    export
endif

# Playbook and tag selector. Override on the command line, e.g.:
#   make run PLAYBOOK=verify-terra.yml
PLAYBOOK ?= HomeServer__HomeAssistant.yml
TAGS ?=

include Makefile.Log

run:
	ANSIBLE_CONFIG=${ANSIBLE_CONFIG} $(RUN_LOG) $(LOG_LABEL) ./bin/dot-bootstrap $(PLAYBOOK) $(TAGS)

run-terra:
	ANSIBLE_CONFIG=${ANSIBLE_CONFIG} $(RUN_LOG) run-terra ./bin/dot-bootstrap $(PLAYBOOK) all

.PHONY: vault-init-terra vault-edit-terra

# Create (if missing) and encrypt the host vault.
vault-init-terra: | .vault_pass.py
	@mkdir -p ./group_vars/terra
	@test -f ./group_vars/terra/vault || printf -- '---\n' > ./group_vars/terra/vault
	ANSIBLE_CONFIG=ansible.cfg $(RUN_LOG) vault-init ansible-vault encrypt --encrypt-vault-id default --vault-password-file ./.vault_pass.py ./group_vars/terra/vault

# TODO: Move to snakemake and add optional param for host.
# Interactive editor: intentionally not logged.
vault-edit-terra: | .vault_pass.py
	ANSIBLE_CONFIG=ansible.cfg ansible-vault edit --vault-password-file ./.vault_pass.py ./group_vars/terra/vault

install requirements.yml:
	$(RUN_LOG) install ansible-galaxy install -r requirements.yml

# TODO: Move to snakemake and add optional param for host.
facts:
	ANSIBLE_CONFIG=ansible.cfg $(RUN_LOG) facts ansible terra -m ansible.builtin.setup

test:
	ANSIBLE_CONFIG=ansible.cfg $(RUN_LOG) verify ansible-playbook ./verify-terra.yml -v

check:
	$(RUN_LOG) check bash -c 'set -e; \
	  ANSIBLE_CONFIG=ansible.cfg ansible-playbook ./HomeServer__HomeAssistant.yml --syntax-check; \
	  ANSIBLE_CONFIG=ansible.cfg ansible-playbook ./verify-terra.yml --syntax-check; \
	  ANSIBLE_CONFIG=ansible.cfg ansible-playbook ./deploy-nikolaigogol.yml --syntax-check; \
	  ANSIBLE_CONFIG=ansible.cfg ansible-playbook ./verify-nikolaigogol.yml --syntax-check'

lint:
	$(RUN_LOG) lint ansible-lint

# --- Testing -----------------------------------------------------------------
# unit       — repository/structure invariants (no Ansible needed)
# it-*       — integration against the mock @terra container
# e2e        — against the real NAS (mutating, run deliberately)
unit:
	python3 -m pytest tests/unit -v

it-up:
	docker compose -f tests/integration/docker-compose.yml up -d --build

it-run:
	ANSIBLE_CONFIG=ansible.cfg ANSIBLE_ROLES_PATH=$(CURDIR)/roles \
	$(RUN_LOG) integration ansible-playbook -i tests/integration/inventory.ini tests/integration/playbook.yml -v

it-shell:
	docker compose -f tests/integration/docker-compose.yml exec terra-mock bash

it-down:
	docker compose -f tests/integration/docker-compose.yml down -v

e2e:
	$(RUN_LOG) e2e bash -c 'set -e; \
	  ANSIBLE_CONFIG=ansible.cfg ansible-playbook ./HomeServer__HomeAssistant.yml -v; \
	  ANSIBLE_CONFIG=ansible.cfg ansible-playbook ./verify-terra.yml -v'

help:
	@echo "Primary targets:"
	@echo "  install               install galaxy role + collections"
	@echo "  run [TAGS=<tag>]      run the Layer-0 playbook (logged)"
	@echo "  test                  verify @terra (nix / docker / daemon)"
	@echo "  check                 syntax-check the playbooks"
	@echo "  unit                  python unit tests (tests/unit)"
	@echo "  it-up/it-run/it-down  integration against the mock container"
	@echo "  e2e                   run against the real NAS"
	@echo "  lint                  ansible-lint"
	@echo "  run-log               logged ad-hoc cmd: make run-log CMD='...'"
	@echo "  logs                  every ansible target -> logs/latest.log"
	@echo "Per-step manual testing: make -f Makefile.<Step> help"
	@echo "  (Makefile.BackupTos, .AccessSsh, .NixBootstrap, .DockerDeployment,"
	@echo "   .Zterra, .NixosImage, .NixosContainer, .NixosEdgeSync)"
	@echo "Layer 1 (@NikolaiGogol): make -f Makefile.NixosImage run, then"
	@echo "  make -f Makefile.NixosContainer run (see README 'Layer 1')."

config:
	$(RUN_LOG) config ansible-config dump
