#!/usr/bin/env python3
"""one entry point for the whole project. works on windows, macos and linux.

usage, from the repository root:
    python main.py            rebuild the database from nothing and run the solution
    python main.py race       run the race test once
    python main.py race 10    run it 10 times, output saved to benchmarks/race_test_runs.txt
    python main.py test       run every test in tests/ (extra words go to pytest, e.g. -k place_order)
    python main.py psql       open an interactive psql prompt (\\q to quit)
    python main.py all        rebuild, then run the race test once
    python main.py sql sql/08_monday_report.sql
                              run one sql file and print the output

only needs docker and python 3. psql runs inside the container, so it doesn't need to be
installed. the database password lives in .env (created with a random one on first run),
which git ignores.
"""

import hashlib
import os
import secrets
import string
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent
ENV_FILE = REPO / ".env"
# the exact postgres build every figure in docs/ was measured on.
IMAGE = "postgres:18.7"
QUIET = ["-e", "PGOPTIONS=-c client_min_messages=warning"]


# prints an error and stops with a non-zero exit code, so scripts and ci can tell it failed.
def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


# reads the database settings from .env. if there's no .env yet, creates one with a random
# 24-character password, so no password ever has to live in the repository.
def load_env():
    if not ENV_FILE.exists() or "POSTGRES_PASSWORD" not in ENV_FILE.read_text():
        alphabet = "".join(c for c in string.ascii_letters + string.digits if c not in "lIO01o")
        password = "".join(secrets.choice(alphabet) for _ in range(24))
        ENV_FILE.write_text(
            "# local database settings. private to this machine, never commit this file.\n"
            "POSTGRES_CONTAINER=kloudkart\n"
            "POSTGRES_PORT=5433\n"
            "POSTGRES_DB=kloudkart\n"
            f"POSTGRES_PASSWORD={password}\n"
        )
        print("created .env with a new random database password")

    env = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    env.setdefault("POSTGRES_CONTAINER", "kloudkart")
    env.setdefault("POSTGRES_PORT", "5433")
    env.setdefault("POSTGRES_DB", "kloudkart")
    env["DATABASE_URL"] = (
        f"postgresql://postgres:{env['POSTGRES_PASSWORD']}"
        f"@127.0.0.1:{env['POSTGRES_PORT']}/{env['POSTGRES_DB']}"
    )
    return env


# runs a docker command. when check is on it returns nothing on failure instead of raising,
# so callers can decide what a failure means. a missing docker stops with a clear message.
def docker(*args, check=True, capture=False):
    try:
        result = subprocess.run(["docker", *args], capture_output=capture, text=True)
    except FileNotFoundError:
        fail("docker isn't installed or isn't on PATH. install Docker Desktop and start it.")
    if check and result.returncode != 0:
        return None
    return result


# runs psql inside the container, so it doesn't need installing on this machine.
# returns psql's exit code. interactive mode opens a prompt you can type into.
def psql(env, *args, workdir="/work", interactive=False):
    flags = ["-it"] if interactive else []
    cmd = ["exec", *flags, *QUIET, "-w", workdir, env["POSTGRES_CONTAINER"],
           "psql", "-U", "postgres", "-d", env["POSTGRES_DB"], "-X", *args]
    return docker(*cmd, check=False).returncode


# compares every supplied file with checksums.sha256 and stops if anything differs, so an
# edited race_test.py or changed csv is caught before it's loaded.
def check_bundle():
    print("checking the supplied bundle against checksums.sha256")
    changed = []
    for line in (REPO / "checksums.sha256").read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        expected, relative = line.split(maxsplit=1)
        relative = relative.lstrip("*")
        path = REPO / relative
        if not path.exists():
            changed.append(f"{relative} (missing)")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != expected.lower():
            changed.append(relative)
    if changed:
        fail("these supplied files differ from what was shipped: " + ", ".join(changed))


# makes sure docker is running, starts the postgres container (creating it the first time,
# reachable only from this computer), then waits up to 60 seconds for it to accept connections.
def start_container(env):
    name = env["POSTGRES_CONTAINER"]
    if docker("info", check=False, capture=True).returncode != 0:
        fail("docker is installed but not running. start Docker Desktop and try again.")

    exists = docker("ps", "-a", "--filter", f"name=^{name}$", "--format", "{{.Names}}", capture=True)
    if exists and exists.stdout.strip():
        docker("start", name, capture=True)
    else:
        print(f"starting a new postgres container '{name}' on 127.0.0.1:{env['POSTGRES_PORT']}")
        started = docker("run", "-d", "--name", name,
                         "-e", f"POSTGRES_PASSWORD={env['POSTGRES_PASSWORD']}",
                         "-p", f"127.0.0.1:{env['POSTGRES_PORT']}:5432",
                         "-v", f"{REPO}:/work",
                         IMAGE, "-c", "max_connections=500", "-c", "shared_buffers=256MB",
                         capture=True)
        if started is None:
            fail(f"could not start the postgres container. is port {env['POSTGRES_PORT']} free?")

    print("waiting for postgres to accept connections")
    deadline = time.time() + 60
    while docker("exec", name, "pg_isready", "-U", "postgres", "-q", check=False).returncode != 0:
        if time.time() > deadline:
            fail(f"postgres did not start within 60 seconds. check: docker logs {name}")
        time.sleep(0.5)


# does the full rebuild: checks the bundle, starts postgres, recreates the database, loads
# the supplied schema and data, then runs sql/run_all.sql, which ends with the self checks.
def build(env):
    check_bundle()
    start_container(env)
    name, db = env["POSTGRES_CONTAINER"], env["POSTGRES_DB"]

    print(f"recreating database '{db}'")
    for statement in (f"DROP DATABASE IF EXISTS {db} WITH (FORCE)", f"CREATE DATABASE {db}"):
        if docker("exec", name, "psql", "-U", "postgres", "-qX", "-d", "postgres",
                  "-c", statement, check=False).returncode != 0:
            fail(f"failed: {statement}")

    print("loading the supplied schema and data")
    if psql(env, "-q", "-v", "ON_ERROR_STOP=1", "-f", "schema.sql", workdir="/work/M03_Resources"):
        fail("schema.sql failed")
    if psql(env, "-v", "ON_ERROR_STOP=1", "-f", "load.sql", workdir="/work/M03_Resources"):
        fail("load.sql failed")

    print("running the solution")
    if psql(env, "-v", "ON_ERROR_STOP=1", "-f", "sql/run_all.sql"):
        fail("run_all.sql failed")

    print("\ndone. next: python main.py race")


# uses the project's .venv python for the race test if it exists, since that's where
# psycopg2 is installed. otherwise falls back to the python running this script.
def python_for_race():
    venv = REPO / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    return str(venv) if venv.exists() else sys.executable


# runs the unmodified race_test.py against the database. one run prints straight to the
# screen; several runs are saved to benchmarks/race_test_runs.txt with a pass count.
def race(env, runs=1):
    child_env = {**os.environ, "DATABASE_URL": env["DATABASE_URL"]}
    cwd = REPO / "M03_Resources"
    python = python_for_race()

    if runs == 1:
        sys.exit(subprocess.run([python, "race_test.py"], cwd=cwd, env=child_env).returncode)

    out = REPO / "benchmarks" / "race_test_runs.txt"
    passed = 0
    with out.open("w", encoding="utf-8") as f:
        f.write(f"race_test.py, {runs} consecutive runs, {datetime.now():%Y-%m-%d %H:%M}\n")
        for i in range(1, runs + 1):
            result = subprocess.run([python, "race_test.py"], cwd=cwd, env=child_env,
                                    capture_output=True, text=True)
            f.write(f"\n######## run {i} of {runs} ########\n{result.stdout}{result.stderr}")
            ok = result.returncode == 0
            passed += ok
            print(f"run {i}: {'passed' if ok else 'FAILED'}")
        f.write(f"\nsummary: {passed} of {runs} runs passed\n")
    print(f"{passed} of {runs} runs passed. full output in benchmarks/race_test_runs.txt")
    sys.exit(0 if passed == runs else 1)


# runs the tests in tests/ with pytest from the project's .venv. the database tests use the
# build made by `python main.py`, and are skipped if it isn't running.
def run_tests(extra_args):
    sys.exit(subprocess.run([python_for_race(), "-m", "pytest", *extra_args], cwd=REPO).returncode)


# reads the command from the command line and runs it. no command means a full rebuild,
# and an unknown one prints the usage at the top of this file.
def main():
    # keeps our lines in order with psql's output.
    sys.stdout.reconfigure(line_buffering=True)
    args = sys.argv[1:]
    command = args[0] if args else "build"
    env = load_env()

    if command == "build":
        build(env)
    elif command == "all":
        build(env)
        race(env)
    elif command == "race":
        race(env, int(args[1]) if len(args) > 1 else 1)
    elif command == "test":
        run_tests(args[1:])
    elif command == "sql":
        if len(args) < 2:
            fail("which file? e.g. python main.py sql sql/08_monday_report.sql")
        target = Path(args[1])
        if not (REPO / target).exists():
            fail(f"{target} not found (paths are relative to the repository root)")
        sys.exit(psql(env, "-P", "pager=off", "-f", target.as_posix()))
    elif command == "psql":
        sys.exit(psql(env, interactive=True))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
