from cc_use.screen import normalize_screen, snapshot_from_text


def test_normalize_screen_removes_ansi_and_trailing_blank_lines() -> None:
    text = "\x1b[31mhello\x1b[0m  \nworld\n\n"

    assert normalize_screen(text) == "hello\nworld"


def test_snapshot_digest_is_stable_for_trailing_blank_lines() -> None:
    left = snapshot_from_text("hello\n")
    right = snapshot_from_text("hello\n\n")

    assert left.digest == right.digest
