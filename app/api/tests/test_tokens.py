import os

from api.tokens import Tokens


def write(path, text, mtime):
    path.write_text(text)
    os.utime(path, (mtime, mtime))


def test_missing_file_means_not_configured(tmp_path):
    tokens = Tokens(str(tmp_path / "absent"))
    assert tokens.configured() is False
    assert tokens.valid("anything") is False


def test_one_token_per_line_blank_lines_ignored(tmp_path):
    f = tmp_path / "tokens"
    write(f, "old-token\n\n  new-token  \n", 1)
    tokens = Tokens(str(f))
    assert tokens.configured() is True
    assert tokens.valid("old-token") is True
    assert tokens.valid("new-token") is True
    assert tokens.valid("new") is False
    assert tokens.valid("") is False


def test_picks_up_a_rotation_without_restart(tmp_path):
    f = tmp_path / "tokens"
    write(f, "first\n", 1)
    tokens = Tokens(str(f))
    assert tokens.valid("first") is True
    write(f, "second\n", 2)
    assert tokens.valid("first") is False
    assert tokens.valid("second") is True


def test_file_removed_turns_it_off(tmp_path):
    f = tmp_path / "tokens"
    write(f, "t\n", 1)
    tokens = Tokens(str(f))
    assert tokens.configured() is True
    f.unlink()
    assert tokens.configured() is False


def test_path_from_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("ADMIN_TOKENS_FILE", str(tmp_path / "x"))
    assert Tokens().path == tmp_path / "x"
