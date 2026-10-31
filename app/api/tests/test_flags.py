import os

from api.flags import Flags


def write(path, text, mtime):
    path.write_text(text)
    os.utime(path, (mtime, mtime))


def test_missing_file_means_off(tmp_path):
    assert Flags(str(tmp_path / "absent.json")).enabled("quotes") is False


def test_reads_flags_and_only_true_is_on(tmp_path):
    f = tmp_path / "flags.json"
    write(f, '{"quotes": true, "beta": "yes", "gamma": 1}', 1)
    flags = Flags(str(f))
    assert flags.enabled("quotes") is True
    assert flags.enabled("beta") is False
    assert flags.enabled("gamma") is False
    assert flags.enabled("unknown") is False


def test_picks_up_a_change_without_restart(tmp_path):
    f = tmp_path / "flags.json"
    write(f, '{"quotes": false}', 1)
    flags = Flags(str(f))
    assert flags.enabled("quotes") is False
    write(f, '{"quotes": true}', 2)
    assert flags.enabled("quotes") is True


def test_bad_json_keeps_last_good_values(tmp_path):
    f = tmp_path / "flags.json"
    write(f, '{"quotes": true}', 1)
    flags = Flags(str(f))
    assert flags.enabled("quotes") is True
    write(f, '{"quotes": tru', 2)
    assert flags.enabled("quotes") is True


def test_non_object_means_all_off(tmp_path):
    f = tmp_path / "flags.json"
    write(f, '["quotes"]', 1)
    assert Flags(str(f)).enabled("quotes") is False


def test_file_removed_turns_everything_off(tmp_path):
    f = tmp_path / "flags.json"
    write(f, '{"quotes": true}', 1)
    flags = Flags(str(f))
    assert flags.enabled("quotes") is True
    f.unlink()
    assert flags.enabled("quotes") is False


def test_path_from_environment(tmp_path, monkeypatch):
    f = tmp_path / "env.json"
    write(f, '{"quotes": true}', 1)
    monkeypatch.setenv("FLAGS_FILE", str(f))
    assert Flags().enabled("quotes") is True
