"""Contract tests for the Django introspection scripts.

These tests run the real scripts against the bundled test project, so they
verify the JSON contract consumed by the Lua plugin.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "scripts"


def run_script(script_name: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    """Run a script with the current interpreter from the repository root."""
    script_path = SCRIPTS_DIR / script_name
    assert script_path.is_file(), f"missing script: {script_path}"

    full_env = os.environ.copy()
    # Let the script resolve the settings module from manage.py
    full_env.pop("DJANGO_SETTINGS_MODULE", None)
    if env:
        full_env.update(env)

    return subprocess.run(
        [sys.executable, str(script_path)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env=full_env,
        timeout=180,
    )


def decode_stdout(proc: subprocess.CompletedProcess[str]):
    assert proc.returncode == 0, f"script failed:\n{proc.stderr}"
    return json.loads(proc.stdout)


def test_get_models_returns_models() -> None:
    models = decode_stdout(run_script("get_models.py"))

    assert isinstance(models, list)
    assert models, "expected at least one model"

    for model in models:
        assert {
            "name",
            "app_label",
            "db_table",
            "field_count",
            "file",
            "line",
            "pos",
            "module",
        } <= model.keys()

    keys = {(model["app_label"], model["name"]) for model in models}
    assert ("blog", "Post") in keys
    assert ("blog", "Comment") in keys


def test_get_views_returns_endpoints() -> None:
    endpoints = decode_stdout(run_script("get_views.py"))

    assert isinstance(endpoints, list)
    assert endpoints, "expected at least one endpoint"

    for endpoint in endpoints:
        assert {"pattern", "name", "view", "view_name", "file", "line", "pos"} <= endpoint.keys()
        assert isinstance(endpoint["pattern"], str)

    class_based = [endpoint for endpoint in endpoints if "method" in endpoint]
    assert class_based, "expected at least one class-based view endpoint"
    for endpoint in class_based:
        assert endpoint["method"] in {"get", "post", "put", "patch", "delete", "head", "options"}


def test_get_completion_data_shape() -> None:
    data = decode_stdout(run_script("get_completion_data.py"))

    assert isinstance(data, dict)
    assert {"models", "lookups"} <= data.keys()

    models = data["models"]
    assert isinstance(models, dict)
    assert models

    post = models.get("Post")
    assert post is not None, "expected the blog Post model"
    assert post["app_label"] == "blog"
    assert post["module"].endswith("blog.models")

    fields = post["fields"]
    assert fields
    assert fields["title"]["type"] == "CharField"
    assert fields["title"]["max_length"] == 200
    assert fields["author"]["type"] == "ForeignKey"
    assert fields["author"]["related_model"] == "User"

    lookups = data["lookups"]
    assert "exact" in lookups["base"]
    assert "isnull" in lookups["base"]
    assert isinstance(lookups["by_type"], dict)
    assert lookups["by_type"], "expected per-field-type lookups"
    assert "CharField" in lookups["by_type"]
    assert "icontains" in lookups["by_type"]["CharField"]

    metadata = lookups["metadata"]
    assert "exact" in metadata
    assert metadata["exact"]["description"]
    assert metadata["exact"]["sql"]


def test_scripts_report_errors_on_stderr() -> None:
    proc = run_script("get_models.py", env={"DJANGO_SETTINGS_MODULE": "does_not_exist.settings"})

    assert proc.returncode == 1
    assert proc.stdout == ""
    error = json.loads(proc.stderr)
    assert error["type"]
    assert error["error"]
