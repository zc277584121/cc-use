from __future__ import annotations

import os
import subprocess
import tempfile
import time


class TmuxError(RuntimeError):
    pass


class TmuxBackend:
    def has_session(self, session: str) -> bool:
        result = subprocess.run(
            ["tmux", "has-session", "-t", session],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0

    def launch(
        self,
        session: str,
        command: str,
        cwd: str | None = None,
        replace: bool = False,
    ) -> None:
        if self.has_session(session):
            if not replace:
                raise TmuxError(f"tmux session already exists: {session}")
            self.kill(session)

        cmd = ["tmux", "new-session", "-d", "-s", session]
        for key, value in os.environ.items():
            cmd.extend(["-e", f"{key}={value}"])
        if cwd:
            cmd.extend(["-c", cwd])
        cmd.append(command)
        self._run(cmd)

    def kill(self, session: str) -> None:
        subprocess.run(
            ["tmux", "kill-session", "-t", session],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    def list_sessions(self) -> list[str]:
        result = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            return []
        return [line for line in result.stdout.splitlines() if line]

    def capture(self, session: str) -> str:
        result = self._run(["tmux", "capture-pane", "-t", session, "-p"])
        return result.stdout

    def send(
        self,
        session: str,
        text: str,
        enter: bool = True,
        clear: bool = True,
        submit_delay: float = 0.3,
        submit_enters: int = 2,
    ) -> None:
        if clear:
            self._run(["tmux", "send-keys", "-t", session, "C-u"])
        buffer_name = f"cc-use-send-{os.getpid()}"
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(text)
            path = f.name
        try:
            self._run(["tmux", "load-buffer", "-b", buffer_name, path])
            self._run(["tmux", "paste-buffer", "-d", "-b", buffer_name, "-t", session])
        finally:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        if enter:
            time.sleep(submit_delay)
            for _ in range(submit_enters):
                self._run(["tmux", "send-keys", "-t", session, "Enter"])
                time.sleep(submit_delay)

    def key(self, session: str, key: str) -> None:
        self._run(["tmux", "send-keys", "-t", session, key])

    def _run(self, cmd: list[str]) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(cmd, text=True, capture_output=True, check=False)
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "tmux command failed"
            raise TmuxError(detail)
        return result
