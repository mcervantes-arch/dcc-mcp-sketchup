"""Safety baseline: pinned core, disabled skills, no telemetry, inches, no scale."""

import os
from pathlib import Path

import pytest
import yaml

from dcc_mcp_sketchup.safety import (
    SafetyError,
    apply_lockdown,
    assert_pinned_core,
    refuse_disabled_skill,
)
from dcc_mcp_sketchup.server import SketchupMcpServer

ROOT = Path(__file__).parents[1]
SKILLS = ROOT / "src" / "dcc_mcp_sketchup" / "skills"


def test_core_dependency_is_pinned_exactly():
    text = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert "dcc-mcp-core==0.20.36" in text
    assert "dcc-mcp-core>=" not in text


def test_pinned_core_refuses_anything_else():
    assert_pinned_core("0.20.36")
    with pytest.raises(SafetyError, match="not the pinned version"):
        assert_pinned_core("0.20.37")
    with pytest.raises(SafetyError, match="not the pinned version"):
        assert_pinned_core("0.20.35")


def test_doctor_core_failure_does_not_suggest_pip_upgrade(monkeypatch):
    from dcc_mcp_sketchup import doctor

    monkeypatch.setattr(doctor, "running_core_version", "0.20.35", raising=False)
    report = doctor.doctor_report("doctor")
    blob = repr(report["next_steps"])

    assert report["verify"]["failure_stage"] == "core"
    assert report["next_steps"][0]["id"] == "stop-core-pin"
    assert "pip" not in blob
    assert "--upgrade" not in blob


def test_disabled_skills_are_refused():
    for name in (
        "ui-control",
        "media",
        "execute_python",
        "execute-python",
        "/opt/skills/ui_control",
        r"C:\skills\Media",
    ):
        with pytest.raises(SafetyError, match="disabled skill refused"):
            refuse_disabled_skill(name)


def test_bundled_skills_and_skill_paths_fail_closed(monkeypatch):
    server = SketchupMcpServer.__new__(SketchupMcpServer)
    with pytest.raises(SafetyError, match="disabled skills refused"):
        server.register_builtin_actions(include_bundled=True)
    with pytest.raises(SafetyError, match="disabled skill refused"):
        server.register_builtin_actions(extra_skill_paths=["/tmp/execute_python"])

    monkeypatch.setenv("DCC_EXTRA_SKILL_PATH", "/opt/media")
    with pytest.raises(SafetyError, match="disabled skill refused"):
        server.register_builtin_actions()


def test_lockdown_strips_otlp_and_webhooks(monkeypatch):
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
    monkeypatch.setenv("OTEL_SERVICE_NAME", "sketchup")
    monkeypatch.setenv("DCC_MCP_WEBHOOK_URL", "http://127.0.0.1/hook")
    apply_lockdown()

    assert "OTEL_EXPORTER_OTLP_ENDPOINT" not in os.environ
    assert "OTEL_SERVICE_NAME" not in os.environ
    assert "DCC_MCP_WEBHOOK_URL" not in os.environ
    assert os.environ["DCC_MCP_DISABLE_TELEMETRY"] == "1"


def test_wrong_core_still_locks_down_before_refusing(monkeypatch):
    import dcc_mcp_sketchup.server as server_module

    monkeypatch.setenv("DCC_MCP_SKETCHUP_HOST_PID", "4242")
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
    monkeypatch.setenv("DCC_WEBHOOK_SECRET", "nope")
    monkeypatch.setattr(server_module, "running_core_version", "9.9.9")

    with pytest.raises(SafetyError, match="not the pinned version"):
        SketchupMcpServer()

    assert "OTEL_EXPORTER_OTLP_ENDPOINT" not in os.environ
    assert "DCC_WEBHOOK_SECRET" not in os.environ
    assert os.environ["DCC_MCP_DISABLE_TELEMETRY"] == "1"


def test_missing_host_pid_raises_before_lockdown(monkeypatch):
    monkeypatch.delenv("DCC_MCP_SKETCHUP_HOST_PID", raising=False)
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")

    with pytest.raises(ValueError, match="live SketchUp host PID"):
        SketchupMcpServer(host_pid=0)

    assert os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://127.0.0.1:4318"


def test_materials_skill_and_save_model_are_gone():
    assert not (SKILLS / "sketchup-materials").exists()
    assert not (SKILLS / "sketchup-session" / "scripts" / "save_model.py").exists()
    session = yaml.safe_load(
        (SKILLS / "sketchup-session" / "tools.yaml").read_text(encoding="utf-8")
    )
    names = {tool["name"] for tool in session["tools"]}
    assert "save_model" not in names
    assert "save_copy" in names
    save_copy = next(tool for tool in session["tools"] if tool["name"] == "save_copy")
    assert "overwrite" not in save_copy["input_schema"]["properties"]


def test_transform_has_no_scale_and_lengths_default_to_inches():
    modeling = yaml.safe_load(
        (SKILLS / "sketchup-modeling" / "tools.yaml").read_text(encoding="utf-8")
    )
    by_name = {tool["name"]: tool for tool in modeling["tools"]}
    transform = by_name["transform_entity"]["input_schema"]["properties"]
    assert "scale" not in transform
    assert transform["unit"]["default"] == "inches"
    assert by_name["add_box"]["input_schema"]["properties"]["unit"]["default"] == "inches"
    assert by_name["add_cylinder"]["input_schema"]["properties"]["unit"]["default"] == "inches"
