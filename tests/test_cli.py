"""Tests for the CLI surface (parser + command dispatch)."""

from __future__ import annotations

from emload import cli


def test_parser_has_expected_commands():
    parser = cli.build_parser()
    commands = {action.dest: action for action in parser._actions}
    sub = commands["command"]
    names = sub.choices.keys()
    for expected in (
        "doctor", "devices", "device-info", "login", "logout", "account",
        "teams", "provision", "inspect", "sideload", "refresh", "installs",
        "forget", "apps", "jit", "uninstall", "profiles", "unprovision", "signed",
        "setup", "emstore-server", "gui", "version",
    ):
        assert expected in names


def test_version_command(capsys):
    assert cli.main(["version"]) == 0
    out = capsys.readouterr().out
    assert "0.1.0" in out


def test_unknown_command_fails():
    import pytest

    with pytest.raises(SystemExit):
        cli.main(["frobnicate"])


def test_doctor_returns_zero(capsys):
    assert cli.main(["doctor"]) == 0
    assert "Python" in capsys.readouterr().out