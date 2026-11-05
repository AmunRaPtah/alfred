from alfredd import adapters

META = {"harness": "alfred", "commands": ["context", "compact", "clear", "doctor", "dataviz"]}


def test_known_commands_hides_terminal_only_and_leads_with_runner_ones():
    assert adapters.known_commands(META) == ["new", "clear", "context", "compact", "dataviz"]


def test_normalize_lowercases_known_command_word_only():
    assert adapters.normalize_slash("/Context", META) == "/context"
    assert adapters.normalize_slash("/Dataviz Sales BY month", META) == "/dataviz Sales BY month"


def test_normalize_leaves_paths_and_plain_text_alone():
    assert adapters.normalize_slash("/Users/foo/bar.txt", META) == "/Users/foo/bar.txt"
    assert adapters.normalize_slash("Hello", META) == "Hello"


def test_slash_name():
    assert adapters.slash_name("/compact keep the plan") == "compact"
    assert adapters.slash_name("// comment") is None
    assert adapters.slash_name("hi /x") is None
