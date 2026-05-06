from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class WatchState:
    session: str
    last_digest: str | None = None
    last_changed_at: float | None = None
    silence_started_at: float | None = None
    last_observed_at: float | None = None
    next_check_at: float | None = None
    observation_count: int = 0
    last_observation: dict[str, Any] | None = None
    recent_digests: list[str] = field(default_factory=list)


def load_state(path: Path, session: str) -> WatchState:
    if not path.exists():
        return WatchState(session=session)
    data = json.loads(path.read_text())
    data.setdefault("session", session)
    data.setdefault("recent_digests", [])
    return WatchState(**data)


def save_state(path: Path, state: WatchState) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(state), indent=2, sort_keys=True) + "\n")


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")


def state_summary(state: WatchState, now: float) -> dict[str, Any]:
    silence_seconds = None
    if state.silence_started_at is not None:
        silence_seconds = max(0.0, now - state.silence_started_at)

    seconds_until_next_check = None
    if state.next_check_at is not None:
        seconds_until_next_check = max(0.0, state.next_check_at - now)

    return {
        "session": state.session,
        "last_digest": state.last_digest,
        "last_changed_at": state.last_changed_at,
        "silence_started_at": state.silence_started_at,
        "silence_seconds": None if silence_seconds is None else round(silence_seconds, 3),
        "last_observed_at": state.last_observed_at,
        "next_check_at": state.next_check_at,
        "seconds_until_next_check": (
            None if seconds_until_next_check is None else round(seconds_until_next_check, 3)
        ),
        "observation_count": state.observation_count,
        "last_observation": state.last_observation,
    }
