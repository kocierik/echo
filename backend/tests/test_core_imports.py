"""The base modules of run tracking stay below the rest of the app (BR1.9).

core/runs.py, core/request_budget.py and core/redaction.py must never load the actions,
services, agents or workers packages: otherwise the base every agent builds on could
reach the providers or the agent loop, and import cycles would follow. Each module is
imported in a fresh interpreter, so what other tests loaded does not count.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

BACKEND = Path(__file__).parents[1]
FORBIDDEN = ("app.actions", "app.services", "app.agents", "app.workers")
CORE_MODULES = ("app.core.runs", "app.core.request_budget", "app.core.redaction")

_PROBE = """
import importlib, json, sys
importlib.import_module(sys.argv[1])
print(json.dumps(sorted(m for m in sys.modules if m.startswith("app."))))
"""


def _loaded_by(module: str) -> list[str]:
    result = subprocess.run(
        [sys.executable, "-c", _PROBE, module],
        cwd=BACKEND,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


@pytest.mark.parametrize("module", CORE_MODULES)
def test_core_module_loads_no_app_layer_above_it(module):
    loaded = _loaded_by(module)

    assert module in loaded
    leaked = [m for m in loaded if m.startswith(FORBIDDEN)]
    assert leaked == []


def test_the_probe_would_see_a_forbidden_import():
    # actions/audit.py imports core/redaction.py, never the other way round
    assert "app.core.redaction" in _loaded_by("app.actions.audit")
    assert any(m.startswith("app.actions") for m in _loaded_by("app.actions.audit"))
