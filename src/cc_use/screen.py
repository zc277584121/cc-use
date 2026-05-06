from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


@dataclass(frozen=True)
class ScreenSnapshot:
    text: str
    normalized: str
    digest: str


def normalize_screen(text: str) -> str:
    cleaned = ANSI_RE.sub("", text)
    lines = [line.rstrip() for line in cleaned.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def snapshot_from_text(text: str) -> ScreenSnapshot:
    normalized = normalize_screen(text)
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    return ScreenSnapshot(text=text, normalized=normalized, digest=digest)
