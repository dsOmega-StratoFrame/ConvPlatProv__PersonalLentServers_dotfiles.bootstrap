"""Regression wrapper for the hermetic host-permit harness.

``tests/manilov/host-permit/run.sh`` exercises ``scripts/manilov/host-permit.sh``
against a stateful fake ``nft`` and a fake ``id``.  It needs no root, no real
nft, no network and no host state; this wrapper only adds the fake bin directory
to ``PATH`` and runs it in pytest's temporary directory.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
RUN = REPO / "tests" / "manilov" / "host-permit" / "run.sh"
FAKE_BIN = REPO / "tests" / "manilov" / "host-permit" / "fake-bin"
BASH = shutil.which("bash")


@pytest.mark.skipif(BASH is None, reason="bash is required to run the host-permit harness")
def test_host_permit_harness(tmp_path: Path) -> None:
    env = os.environ.copy()
    env["PATH"] = f"{FAKE_BIN}{os.pathsep}{env.get('PATH', '')}"
    env["PYTHON"] = sys.executable
    env["TMPDIR"] = str(tmp_path)

    completed = subprocess.run(
        [BASH, str(RUN)],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=300,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, "host-permit harness failed:\n" + output

    summary = re.search(r"(\d+) passed, (\d+) failed", completed.stdout)
    assert summary is not None, "harness produced no summary:\n" + output
    passed, failed = (int(value) for value in summary.groups())
    assert passed > 0, "harness ran no cases:\n" + output
    assert failed == 0, "harness reported failures:\n" + output
