from cc_use.observer import estimate_next_check


def test_estimate_next_check_for_quiet_test_run() -> None:
    decision = estimate_next_check("Running pytest", silence_seconds=40)

    assert decision.action == "wait"
    assert decision.next_check_after_seconds == 120


def test_estimate_next_check_for_permission_prompt() -> None:
    decision = estimate_next_check("Allow this command?", silence_seconds=40)

    assert decision.action == "intervene"


def test_estimate_next_check_ignores_codex_welcome_build_tip() -> None:
    decision = estimate_next_check("Tip: New Build faster with the Codex App.", silence_seconds=40)

    assert decision.next_check_after_seconds == 60
