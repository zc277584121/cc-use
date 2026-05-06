from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from cc_use.project import (
    ProjectConfig,
    build_codex_command,
    build_inner_task_prompt,
    default_session_name,
    load_project_config,
    save_project_config,
    watch_state_path,
)
from cc_use.screen import snapshot_from_text
from cc_use.state import load_state, state_summary
from cc_use.tmux import TmuxBackend
from cc_use.watch import watch_session


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cc-use")
    subparsers = parser.add_subparsers(dest="command", required=True)

    launch = subparsers.add_parser("launch", help="Launch a command in a tmux session.")
    launch.add_argument("session")
    launch.add_argument("--cmd", default="codex", help="Command to run inside tmux.")
    launch.add_argument("--cwd", default=None, help="Working directory for the tmux session.")
    launch.add_argument("--replace", action="store_true", help="Replace an existing tmux session.")

    codex = subparsers.add_parser("codex", help="Launch Codex CLI in a tmux session.")
    codex.add_argument("session")
    codex.add_argument("--profile", default="zilliz")
    codex.add_argument("--cwd", default=None)
    codex.add_argument("--replace", action="store_true")
    codex.add_argument("--sandbox", default="workspace-write")
    codex.add_argument("--approval", default="never")
    codex.add_argument("--auto-trust", action="store_true", help="Press Enter after startup for Codex trust prompts.")
    codex.add_argument("--settle-seconds", type=float, default=5.0)

    delegate = subparsers.add_parser("delegate", help="Project-level entry point for skills: launch if needed, send task, watch once.")
    delegate.add_argument("task")
    delegate.add_argument("--project", default=".")
    delegate.add_argument("--session", default=None)
    delegate.add_argument("--agent", choices=["codex"], default="codex")
    delegate.add_argument("--profile", default="zilliz")
    delegate.add_argument("--sandbox", default="workspace-write")
    delegate.add_argument("--approval", default="never")
    delegate.add_argument("--replace", action="store_true")
    delegate.add_argument("--auto-trust", action="store_true", default=True)
    delegate.add_argument("--settle-seconds", type=float, default=5.0)
    delegate.add_argument("--poll-interval", type=float, default=2.0)
    delegate.add_argument("--initial-quiet-seconds", type=float, default=30.0)
    delegate.add_argument("--max-observations", type=int, default=1)

    monitor = subparsers.add_parser("monitor", help="Project-level watch using .cc-use/state/session-info.json.")
    monitor.add_argument("--project", default=".")
    monitor.add_argument("--poll-interval", type=float, default=2.0)
    monitor.add_argument("--initial-quiet-seconds", type=float, default=30.0)
    monitor.add_argument("--max-observations", type=int, default=1)

    project_status = subparsers.add_parser("project-status", help="Show project-level cc-use state.")
    project_status.add_argument("--project", default=".")
    project_status.add_argument("--json", action="store_true")

    send = subparsers.add_parser("send", help="Send text to a tmux session.")
    send.add_argument("session")
    send.add_argument("text")
    send.add_argument("--no-enter", action="store_true")
    send.add_argument("--no-clear", action="store_true", help="Do not clear the current input line before sending.")
    send.add_argument("--submit-delay", type=float, default=0.3)
    send.add_argument("--submit-enters", type=int, default=2)

    key = subparsers.add_parser("key", help="Send one key to a tmux session.")
    key.add_argument("session")
    key.add_argument("key", help="tmux key name, for example Enter, C-c, or C-m.")

    list_cmd = subparsers.add_parser("list", help="List tmux sessions.")
    list_cmd.add_argument("--json", action="store_true")

    ask = subparsers.add_parser("ask", help="Send a prompt and optionally watch for quiet-period observation.")
    ask.add_argument("session")
    ask.add_argument("text")
    ask.add_argument("--state", default=".cc-use/state/watch.json")
    ask.add_argument("--poll-interval", type=float, default=2.0)
    ask.add_argument("--initial-quiet-seconds", type=float, default=30.0)
    ask.add_argument("--max-observations", type=int, default=1)
    ask.add_argument("--no-watch", action="store_true")
    ask.add_argument("--submit-delay", type=float, default=0.3)
    ask.add_argument("--submit-enters", type=int, default=2)

    snapshot = subparsers.add_parser("snapshot", help="Capture the current tmux session screen.")
    snapshot.add_argument("session")
    snapshot.add_argument("--hash", action="store_true", help="Only print the normalized screen hash.")

    watch = subparsers.add_parser("watch", help="Watch screen changes and observe after quiet periods.")
    watch.add_argument("session")
    watch.add_argument("--state", default=".cc-use/state/watch.json")
    watch.add_argument("--poll-interval", type=float, default=2.0)
    watch.add_argument("--initial-quiet-seconds", type=float, default=30.0)
    watch.add_argument("--max-observations", type=int, default=None)
    watch.add_argument("--history", default=None, help="Observation history jsonl path.")
    watch.add_argument("--snapshots-dir", default=None, help="Directory for observed screen snapshots.")

    status = subparsers.add_parser("status", help="Show watcher state for a tmux session.")
    status.add_argument("session")
    status.add_argument("--state", default=".cc-use/state/watch.json")
    status.add_argument("--json", action="store_true", help="Print machine-readable JSON.")

    kill = subparsers.add_parser("kill", help="Kill a tmux session.")
    kill.add_argument("session")

    return parser


def main() -> None:
    args = build_parser().parse_args()
    tmux = TmuxBackend()

    if args.command == "launch":
        tmux.launch(
            args.session,
            args.cmd,
            cwd=args.cwd,
            replace=args.replace,
        )
        print(f"launched {args.session}: {args.cmd}")
    elif args.command == "codex":
        command = build_codex_command(args.profile, args.sandbox, args.approval)
        tmux.launch(args.session, command, cwd=args.cwd, replace=args.replace)
        print(f"launched {args.session}: {command}")
        if args.auto_trust:
            time.sleep(args.settle_seconds)
            tmux.key(args.session, "Enter")
    elif args.command == "delegate":
        project_dir = Path(args.project).resolve()
        session = args.session or default_session_name(project_dir)
        config = ProjectConfig(
            project_dir=str(project_dir),
            session=session,
            agent=args.agent,
            profile=args.profile,
            sandbox=args.sandbox,
            approval=args.approval,
        )
        save_project_config(config)

        if args.replace or not tmux.has_session(session):
            command = build_codex_command(args.profile, args.sandbox, args.approval)
            tmux.launch(session, command, cwd=str(project_dir), replace=args.replace)
            print(f"launched {session}: {command}", flush=True)
            if args.auto_trust:
                time.sleep(args.settle_seconds)
                tmux.key(session, "Enter")
                time.sleep(1)

        tmux.send(session, build_inner_task_prompt(args.task))
        watch_session(
            session,
            watch_state_path(project_dir),
            poll_interval=args.poll_interval,
            initial_quiet_seconds=args.initial_quiet_seconds,
            max_observations=args.max_observations,
        )
    elif args.command == "monitor":
        project_dir = Path(args.project).resolve()
        config = load_project_config(project_dir)
        watch_session(
            config.session,
            watch_state_path(project_dir),
            poll_interval=args.poll_interval,
            initial_quiet_seconds=args.initial_quiet_seconds,
            max_observations=args.max_observations,
        )
    elif args.command == "project-status":
        project_dir = Path(args.project).resolve()
        config = load_project_config(project_dir)
        state = load_state(watch_state_path(project_dir), config.session)
        summary = state_summary(state, time.time())
        payload = {"config": config.__dict__, "watch": summary}
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print(f"project: {config.project_dir}")
            print(f"session: {config.session}")
            print(f"agent: {config.agent}")
            print(f"observations: {summary['observation_count']}")
            print(f"silence_seconds: {summary['silence_seconds']}")
            print(f"seconds_until_next_check: {summary['seconds_until_next_check']}")
    elif args.command == "send":
        tmux.send(
            args.session,
            args.text,
            enter=not args.no_enter,
            clear=not args.no_clear,
            submit_delay=args.submit_delay,
            submit_enters=args.submit_enters,
        )
    elif args.command == "key":
        tmux.key(args.session, args.key)
    elif args.command == "list":
        sessions = tmux.list_sessions()
        if args.json:
            print(json.dumps({"sessions": sessions}, indent=2, sort_keys=True))
        else:
            for session in sessions:
                print(session)
    elif args.command == "ask":
        tmux.send(args.session, args.text, submit_delay=args.submit_delay, submit_enters=args.submit_enters)
        if not args.no_watch:
            watch_session(
                args.session,
                Path(args.state),
                poll_interval=args.poll_interval,
                initial_quiet_seconds=args.initial_quiet_seconds,
                max_observations=args.max_observations,
            )
    elif args.command == "snapshot":
        snapshot = snapshot_from_text(tmux.capture(args.session))
        print(snapshot.digest if args.hash else snapshot.normalized)
    elif args.command == "watch":
        watch_session(
            args.session,
            Path(args.state),
            poll_interval=args.poll_interval,
            initial_quiet_seconds=args.initial_quiet_seconds,
            max_observations=args.max_observations,
            history_path=None if args.history is None else Path(args.history),
            snapshots_dir=None if args.snapshots_dir is None else Path(args.snapshots_dir),
        )
    elif args.command == "status":
        state = load_state(Path(args.state), args.session)
        summary = state_summary(state, time.time())
        if args.json:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(f"session: {summary['session']}")
            print(f"observations: {summary['observation_count']}")
            print(f"silence_seconds: {summary['silence_seconds']}")
            print(f"seconds_until_next_check: {summary['seconds_until_next_check']}")
            if summary["last_observation"]:
                decision = summary["last_observation"]["decision"]
                print(f"last_action: {decision['action']}")
                print(f"next_check_after_seconds: {decision['next_check_after_seconds']}")
                print(f"reason: {decision['reason']}")
    elif args.command == "kill":
        tmux.kill(args.session)
