"""Fail-closed safety baseline for the RenCo SketchUp adapter.

The rules live in ``AGENTS.md``. This module is the part the Python sidecar
can enforce without a live SketchUp:

* ``dcc-mcp-core`` is pinned to one audited version. A different version
  refuses to run. Nothing here suggests ``pip install --upgrade``.
* The bundled ``ui-control``, ``media``, and ``execute_python`` skills are
  disabled. Asking for one is a hard refusal, not a silent skip.
* Webhook configuration and OTLP telemetry environment variables are removed
  before the server is built, and telemetry is forced off.
"""

from __future__ import annotations

import os

PINNED_CORE_VERSION = "0.20.36"

# Names are compared after the path leaf is taken and ``_`` is folded to ``-``.
DISABLED_SKILLS = frozenset({"ui-control", "media", "execute-python"})

_TELEMETRY_OFF = "DCC_MCP_DISABLE_TELEMETRY"


class SafetyError(RuntimeError):
    """A safety rule refused the request. The adapter does not continue."""


def skill_key(name: str) -> str:
    """Normalize a skill name or a path to that skill."""
    leaf = str(name).replace("\\", "/").rstrip("/").split("/")[-1]
    return leaf.strip().lower().replace("_", "-")


def is_disabled_skill(name: str) -> bool:
    return skill_key(name) in DISABLED_SKILLS


def refuse_disabled_skill(name: str) -> None:
    """Raise when ``name`` is a disabled skill. Fail closed."""
    if is_disabled_skill(name):
        raise SafetyError("disabled skill refused: %s" % name)


def apply_lockdown() -> None:
    """Remove webhook and OTLP configuration and force telemetry off.

    Called before server options are read from the environment, so a variable
    set in the parent process cannot turn telemetry or webhooks back on.
    """
    removed = []
    for key in list(os.environ):
        upper = key.upper()
        if "OTLP" in upper or "WEBHOOK" in upper or upper.startswith("OTEL_"):
            removed.append(key)
    for key in removed:
        os.environ.pop(key, None)
    os.environ[_TELEMETRY_OFF] = "1"


def assert_pinned_core(version: str) -> None:
    """Refuse to run unless ``version`` is the pinned core release."""
    if version != PINNED_CORE_VERSION:
        raise SafetyError(
            "dcc-mcp-core %s is not the pinned version %s; refusing to continue"
            % (version, PINNED_CORE_VERSION)
        )
