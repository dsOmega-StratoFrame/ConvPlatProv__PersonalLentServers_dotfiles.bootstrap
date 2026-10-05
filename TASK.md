# Goal
Step by step fix issues during deployment of `/app/PersonalLentServers%Russian_dotfiles.bootstrap/`.

## Task
I'll try to deploy and throw isuses into you. 
Follow your flow, 

First issue during `make run TAGS=backup`:

```bash
TASK [backup_tos : Stage the out-of-scope extras] ************************************************************************************************
[ERROR]: Task failed: Module failed: The command exited with a non-zero return code.
Origin: /shared/soft-projects-/ds13/Projects/ChronoIndex/2026/PersonalLentServers%Russian_dotfiles.bootstrap/roles/backup_tos/tasks/main.yml:65:3

63   changed_when: false
64
65 - name: Stage the out-of-scope extras
     ^ column 3

fatal: [terra-local]: FAILED! => {
    "changed": false,
    "changed_when_result": false,
    "cmd": "set -e\ndest=\"/var/tmp/backup_tos-terra-local-20261005T190718/extras\"\nmkdir -p \"$dest\"\nfor path in /var/spool/cron /var/lib/samba/private; do\n  if [ -e \"$path\" ]; then\n    cp -a --parents \"$path\" \"$dest/\"\n  fi\ndone\n",
    "delta": "0:00:00.002853",
    "end": "2026-10-05 19:07:21.341569",
    "rc": 1,
    "start": "2026-10-05 19:07:21.338716"
}

STDERR:

cp: cannot access '/var/spool/cron/crontabs': Permission denied


MSG:

The command exited with a non-zero return code.

PLAY RECAP ***************************************************************************************************************************************
terra-local                : ok=6    changed=1    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```


## Environment
- You're in isolated containerized environment.
- You have quite minimal tooling but have nix-shell available. If you need a complex environment (at least multiple new dependencies to install),
use nix-build to create flake.nix. 
- One flake.nix already exists at the repo you're pointed at. It should cover
most dependencies needed for testing.
- You don't have access to SSH and you don't need to access any remote. Ask me - 
I'll send you required info via reports from agent or in chat prompts directly.
