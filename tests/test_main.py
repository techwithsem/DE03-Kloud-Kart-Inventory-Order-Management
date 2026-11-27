"""unit tests for main.py. these need no database or docker."""

import hashlib

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


# checks that the supplied files in this repository still match checksums.sha256.
def test_checksums_match_the_supplied_bundle():
    main.check_bundle()


# checks that editing a supplied file stops the build.
def test_check_bundle_stops_when_a_supplied_file_changes(tmp_path, monkeypatch):
    supplied = tmp_path / "M03_Resources" / "race_test.py"
    supplied.parent.mkdir()
    supplied.write_text("original")
    digest = hashlib.sha256(b"original").hexdigest()
    (tmp_path / "checksums.sha256").write_text(f"# header\n{digest}  M03_Resources/race_test.py\n")
    monkeypatch.setattr(main, "REPO", tmp_path)

    main.check_bundle()

    supplied.write_text("edited")
    with pytest.raises(SystemExit):
        main.check_bundle()


# checks that a missing supplied file stops the build.
def test_check_bundle_stops_when_a_supplied_file_is_missing(tmp_path, monkeypatch):
    (tmp_path / "checksums.sha256").write_text("abc123  M03_Resources/race_test.py\n")
    monkeypatch.setattr(main, "REPO", tmp_path)

    with pytest.raises(SystemExit):
        main.check_bundle()
