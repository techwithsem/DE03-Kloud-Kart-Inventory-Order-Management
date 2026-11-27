"""unit tests for main.py. these need no database or docker."""

import pytest

import main


# points main.py at a temporary .env for the length of one test.
@pytest.fixture
def temp_env(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    monkeypatch.setattr(main, "ENV_FILE", env_file)
    return env_file


# checks that a missing .env is created with a 24-character random password.
def test_load_env_creates_a_random_password_when_env_is_missing(temp_env):
    env = main.load_env()

    assert temp_env.exists()
    assert len(env["POSTGRES_PASSWORD"]) == 24
    assert env["POSTGRES_PASSWORD"] != "kloudkart"


# checks that two fresh .env files never share a password.
def test_load_env_gives_a_new_password_each_time_it_creates_env(temp_env):
    first = main.load_env()["POSTGRES_PASSWORD"]
    temp_env.unlink()
    second = main.load_env()["POSTGRES_PASSWORD"]

    assert first != second


# checks that an existing .env is read as written and the url points at this computer only.
def test_load_env_reads_existing_settings_and_builds_a_local_only_url(temp_env):
    temp_env.write_text(
        "# a comment line\n"
        "POSTGRES_CONTAINER=kk\n"
        "POSTGRES_PORT=6000\n"
        "POSTGRES_DB=shop\n"
        "POSTGRES_PASSWORD=secret123\n"
    )

    env = main.load_env()

    assert env["POSTGRES_CONTAINER"] == "kk"
    assert env["DATABASE_URL"] == "postgresql://postgres:secret123@127.0.0.1:6000/shop"


# checks that settings left out of .env fall back to the defaults.
def test_load_env_fills_in_defaults(temp_env):
    temp_env.write_text("POSTGRES_PASSWORD=abc\n")

    env = main.load_env()

    assert env["POSTGRES_CONTAINER"] == "kloudkart"
    assert env["POSTGRES_PORT"] == "5433"
    assert env["POSTGRES_DB"] == "kloudkart"


# checks that fail stops with exit code 1, so scripts can tell something went wrong.
def test_fail_stops_with_exit_code_one(capsys):
    with pytest.raises(SystemExit) as stopped:
        main.fail("something broke")

    assert stopped.value.code == 1
    assert "something broke" in capsys.readouterr().err


# checks that the race test uses the project's .venv python when there is one.
def test_python_for_race_prefers_the_venv(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "REPO", tmp_path)
    assert main.python_for_race() == main.sys.executable

    venv_python = tmp_path / ".venv" / ("Scripts/python.exe" if main.os.name == "nt" else "bin/python")
    venv_python.parent.mkdir(parents=True)
    venv_python.write_text("")
    assert main.python_for_race() == str(venv_python)
