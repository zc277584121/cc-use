from __future__ import annotations

import json
import time
from dataclasses import asdict
from pathlib import Path

from cc_use.observer import estimate_next_check
from cc_use.screen import snapshot_from_text
from cc_use.state import append_jsonl, load_state, save_state
from cc_use.tmux import TmuxBackend, TmuxError


def watch_session(
    session: str,
    state_path: Path,
    poll_interval: float,
    initial_quiet_seconds: float,
    max_observations: int | None = None,
    history_path: Path | None = None,
    snapshots_dir: Path | None = None,
) -> None:
    tmux = TmuxBackend()
    state = load_state(state_path, session)
    if history_path is None:
        history_path = state_path.with_name(f"{state_path.stem}.observations.jsonl")
    if snapshots_dir is None:
        snapshots_dir = state_path.parent / "screens"

    while True:
        now = time.time()
        try:
            snapshot = snapshot_from_text(tmux.capture(session))
        except TmuxError as exc:
            record = {
                "event": "session_unavailable",
                "session": session,
                "observed_at": now,
                "error": str(exc),
            }
            state.last_observed_at = now
            state.last_observation = record
            save_state(state_path, state)
            append_jsonl(history_path, record)
            print(json.dumps(record, sort_keys=True), flush=True)
            return

        if state.last_digest != snapshot.digest:
            state.last_digest = snapshot.digest
            state.last_changed_at = now
            state.silence_started_at = now
            state.next_check_at = now + initial_quiet_seconds
            state.recent_digests = [*state.recent_digests[-19:], snapshot.digest]
            save_state(state_path, state)
            time.sleep(poll_interval)
            continue

        if state.silence_started_at is None:
            state.silence_started_at = now

        if state.next_check_at is None:
            state.next_check_at = now + initial_quiet_seconds
            save_state(state_path, state)

        if now >= state.next_check_at:
            silence_seconds = now - (state.silence_started_at or now)
            decision = estimate_next_check(snapshot.normalized, silence_seconds)
            snapshot_path = _write_snapshot(snapshots_dir, session, state.observation_count + 1, snapshot.normalized)
            record = {
                "event": "observation",
                "session": session,
                "observed_at": now,
                "silence_seconds": round(silence_seconds, 3),
                "screen_digest": snapshot.digest,
                "screen_path": str(snapshot_path),
                "decision": asdict(decision),
            }
            state.last_observed_at = now
            state.next_check_at = now + decision.next_check_after_seconds
            state.observation_count += 1
            state.last_observation = record
            save_state(state_path, state)
            append_jsonl(history_path, record)

            print(json.dumps(record, sort_keys=True), flush=True)

            if max_observations is not None and state.observation_count >= max_observations:
                return

        sleep_for = min(poll_interval, max(0.1, state.next_check_at - time.time()))
        time.sleep(sleep_for)


def _write_snapshot(snapshots_dir: Path, session: str, observation_number: int, text: str) -> Path:
    snapshots_dir.mkdir(parents=True, exist_ok=True)
    safe_session = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in session)
    path = snapshots_dir / f"{safe_session}-{observation_number:04d}.txt"
    path.write_text(text + "\n")
    return path
