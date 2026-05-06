from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProjectConfig:
    project_dir: str
    session: str
    agent: str
    profile: str
    sandbox: str
    approval: str


def default_session_name(project_dir: Path) -> str:
    name = project_dir.resolve().name or "project"
    safe = "".join(ch if ch.isalnum() or ch in ("-", "_") else "-" for ch in name)
    return f"cc-use-{safe}"


def cc_use_dir(project_dir: Path) -> Path:
    return project_dir / ".cc-use"


def state_dir(project_dir: Path) -> Path:
    return cc_use_dir(project_dir) / "state"


def config_path(project_dir: Path) -> Path:
    return state_dir(project_dir) / "session-info.json"


def watch_state_path(project_dir: Path) -> Path:
    return state_dir(project_dir) / "watch.json"


def save_project_config(config: ProjectConfig) -> None:
    path = config_path(Path(config.project_dir))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(config), indent=2, sort_keys=True) + "\n")


def load_project_config(project_dir: Path) -> ProjectConfig:
    path = config_path(project_dir)
    data = json.loads(path.read_text())
    return ProjectConfig(**data)


def build_codex_command(profile: str, sandbox: str, approval: str) -> str:
    import shlex

    return (
        f"codex --profile {shlex.quote(profile)} --no-alt-screen "
        f"--ask-for-approval {shlex.quote(approval)} --sandbox {shlex.quote(sandbox)}"
    )


def build_inner_task_prompt(task: str) -> str:
    parts = [
        "You are the inner coding agent for cc-use.",
        "Do the requested implementation work directly in the current project directory.",
        "Do not invoke cc-use, do not start another coding agent, and do not ask the user to run commands.",
        "Use your own tools to inspect, edit, and test the project.",
        f"Task: {task}",
    ]
    return " ".join(part.replace("\n", " ") for part in parts)
