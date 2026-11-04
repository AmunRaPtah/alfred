from alfredd.adapters import strip_leaked_reasoning


def test_untouched_without_tags():
    assert strip_leaked_reasoning("  - one\n- two ") == "  - one\n- two "


def test_unopened_close_tag_keeps_answer_only():
    leaked = "- draft a\n- draft b\n</think>\n- final a\n- final b"
    assert strip_leaked_reasoning(leaked) == "- final a\n- final b"


def test_full_block_removed():
    assert strip_leaked_reasoning("<think>plan it</think>\n\nDone, sir.") == "Done, sir."
