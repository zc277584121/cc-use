from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class ObservationDecision:
    action: str
    next_check_after_seconds: int
    confidence: float
    reason: str


def estimate_next_check(screen_text: str, silence_seconds: float) -> ObservationDecision:
    text = screen_text.lower()

    if any(token in text for token in ("permission", "approve", "allow", "continue?", "password")):
        return ObservationDecision(
            action="intervene",
            next_check_after_seconds=15,
            confidence=0.72,
            reason="The terminal may be waiting for explicit user input.",
        )

    if _looks_like_test_or_running_command(text):
        wait = 120 if silence_seconds < 180 else 60
        return ObservationDecision(
            action="wait",
            next_check_after_seconds=wait,
            confidence=0.66,
            reason="The terminal looks like it may be running a command that can stay quiet for a while.",
        )

    if _looks_like_setup_or_build(text):
        return ObservationDecision(
            action="wait",
            next_check_after_seconds=180,
            confidence=0.64,
            reason="The terminal looks like it may be doing long-running setup or build work.",
        )

    if any(token in text for token in ("thinking", "thought", "reasoning")):
        return ObservationDecision(
            action="wait",
            next_check_after_seconds=45,
            confidence=0.61,
            reason="The terminal looks like an agent is reasoning without producing new output.",
        )

    if silence_seconds >= 300:
        return ObservationDecision(
            action="inspect_more",
            next_check_after_seconds=30,
            confidence=0.55,
            reason="The screen has been quiet for a long time without a clear long-running task signal.",
        )

    return ObservationDecision(
        action="wait",
        next_check_after_seconds=60,
        confidence=0.5,
        reason="No screen changes were observed; wait a moderate interval before checking again.",
    )


def _looks_like_test_or_running_command(text: str) -> bool:
    patterns = (
        r"\bpytest\b",
        r"\bnpm\s+test\b",
        r"\bpnpm\s+test\b",
        r"\byarn\s+test\b",
        r"\bcargo\s+test\b",
        r"\bgo\s+test\b",
        r"\brunning\s+(tests?|command|suite|migration|server)\b",
    )
    return any(re.search(pattern, text) for pattern in patterns)


def _looks_like_setup_or_build(text: str) -> bool:
    patterns = (
        r"\bnpm\s+(install|ci|run\s+build)\b",
        r"\bpnpm\s+(install|run\s+build)\b",
        r"\byarn\s+(install|build)\b",
        r"\bpip\s+install\b",
        r"\buv\s+sync\b",
        r"\bbuilding\b",
        r"\bcompil(e|ing)\b",
        r"\bbundling\b",
        r"\binstalling\b",
        r"\bdownloading\b",
    )
    return any(re.search(pattern, text) for pattern in patterns)
