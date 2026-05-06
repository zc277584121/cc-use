from cc_use.state import WatchState, state_summary


def test_state_summary_computes_silence_and_next_check() -> None:
    state = WatchState(
        session="demo",
        silence_started_at=10.0,
        next_check_at=25.0,
        observation_count=2,
    )

    summary = state_summary(state, now=20.0)

    assert summary["silence_seconds"] == 10.0
    assert summary["seconds_until_next_check"] == 5.0
    assert summary["observation_count"] == 2
