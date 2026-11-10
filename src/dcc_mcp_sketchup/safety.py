"""Fail-closed safety baseline for the RenCo SketchUp adapter.

The rules live in ``AGENTS.md``. This module is the part the Python sidecar
can enforce without a live SketchUp:

* ``dcc-mcp-core`` is pinned to one audited version. A different version
  refuses to run. Nothing here suggests ``pip install --upgrade``.
* Only this package's skills are loaded. Bundled core skills, extra skill
  paths, and accumulated skill roots are refused.
* Webhook configuration and OTLP telemetry environment variables are removed
  before the server is built, and telemetry is forced off. A webhooks file
  in the adapter etc directory refuses startup.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

PINNED_CORE_VERSION = "0.20.36"

# Names are compared after the path leaf is taken and ``_`` is folded to ``-``.
DISABLED_SKILLS = frozenset({"ui-control", "media", "execute-python"})
ALLOWED_SKILLS = frozenset({"sketchup-session", "sketchup-modeling", "sketchup-scenes"})
# Core registers these as tools, not as this package's skill directories.
BUILTIN_SKILL_NAMES = frozenset(
    {"diagnostics", "dcc-diagnostics", "introspect", "eval", "qt", "recipes"}
)

_TELEMETRY_OFF = "DCC_MCP_DISABLE_TELEMETRY"
_DISABLE_DEFAULT_SKILL_PATHS = "DCC_MCP_DISABLE_DEFAULT_SKILL_PATHS"
_DISABLE_ACCUMULATED_SKILLS = "DCC_MCP_DISABLE_ACCUMULATED_SKILLS"
_ETC_DIR_ENV = "DCC_MCP_ETC_DIR"

PACKAGE_DIR = Path(__file__).resolve().parent
ETC_DIR = PACKAGE_DIR / "etc"
SKILLS_DIR = PACKAGE_DIR / "skills"


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


def sha256_file(path: Path) -> str:
    """Hash a file. Used to prove a protected synthetic fixture did not change."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def assert_unchanged_hash(path: Path, expected: str) -> None:
    """Raise when ``path`` no longer matches the hash taken before the work."""
    actual = sha256_file(path)
    if actual != expected:
        raise SafetyError("protected file hash changed: %s" % path)


def path_is_inside(path: str, root: Path) -> bool:
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
    except ValueError:
        return False
    return True


def assert_skill_path_allowed(path: str) -> None:
    """Allow a skill path only when it lives in this package's skills folder."""
    refuse_disabled_skill(path)
    if not path_is_inside(path, SKILLS_DIR):
        raise SafetyError("skill path is outside this package: %s" % path)


def assert_loaded_skill_names(names) -> None:
    """Refuse any discovered skill that is not on the package allow-list."""
    unexpected = []
    for name in names:
        key = skill_key(str(name))
        if not key or key in ALLOWED_SKILLS or key in BUILTIN_SKILL_NAMES:
            continue
        unexpected.append(key)
    if unexpected:
        raise SafetyError(
            "loaded skills are outside the allow-list: %s" % ", ".join(sorted(set(unexpected)))
        )


def _is_skill_path_override(key: str) -> bool:
    """True for path overrides, not for the flags that turn those paths off.

    ``DCC_MCP_DISABLE_DEFAULT_SKILL_PATHS`` contains ``SKILL_PATH`` and must
    stay set. ``DCC_MCP_SKILL_PATHS`` is the override that has to go.
    """
    upper = key.upper()
    if upper in {_DISABLE_DEFAULT_SKILL_PATHS, _DISABLE_ACCUMULATED_SKILLS}:
        return False
    return "SKILL_PATH" in upper


def enforce_skill_lock() -> None:
    """Turn off core's default and accumulated skill roots and drop path overrides.

    ``DCC_MCP_DISABLE_DEFAULT_SKILL_PATHS`` does not stop ``DCC_MCP_SKILL_PATHS``.
    A parent skills directory would otherwise load ui-control, media, and
    execute_python. Those variables are removed here.
    """
    os.environ[_DISABLE_DEFAULT_SKILL_PATHS] = "1"
    os.environ[_DISABLE_ACCUMULATED_SKILLS] = "1"
    for key in list(os.environ):
        if _is_skill_path_override(key):
            os.environ.pop(key, None)


def refuse_webhooks_file(etc_dir: Path | None = None) -> None:
    """Refuse to start when a webhooks file is present in the etc directory."""
    directory = Path(etc_dir) if etc_dir is not None else ETC_DIR
    for name in ("webhooks.yaml", "webhooks.yml"):
        candidate = directory / name
        if candidate.exists():
            raise SafetyError("webhooks file is present; refusing to start: %s" % candidate)


def apply_lockdown() -> None:
    """Remove webhook and OTLP configuration and force telemetry off.

    Called before server options are read from the environment, so a variable
    set in the parent process cannot turn telemetry or webhooks back on.
    ``DCC_MCP_ETC_DIR`` is pointed at an empty folder this package owns.
    """
    removed = []
    for key in list(os.environ):
        upper = key.upper()
        if "OTLP" in upper or "WEBHOOK" in upper or upper.startswith("OTEL_"):
            removed.append(key)
        elif _is_skill_path_override(key):
            removed.append(key)
    for key in removed:
        os.environ.pop(key, None)
    os.environ[_TELEMETRY_OFF] = "1"
    enforce_skill_lock()
    os.environ[_ETC_DIR_ENV] = str(ETC_DIR)
    refuse_webhooks_file(ETC_DIR)


def assert_pinned_core(version: str) -> None:
    """Refuse to run unless ``version`` is the pinned core release."""
    if version != PINNED_CORE_VERSION:
        raise SafetyError(
            "dcc-mcp-core %s is not the pinned version %s; refusing to continue"
            % (version, PINNED_CORE_VERSION)
        )
