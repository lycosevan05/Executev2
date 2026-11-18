#!/usr/bin/env python3
"""Run the opted-in native W04 test target against its disposable local stack."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import tomllib
from uuid import UUID

PROJECT_ID = "execute-w04-e59"
LOCAL_API = "http://127.0.0.1:55421"
TEST_TARGET = "ExecuteNativeTests"
TEST_CASE = f"{TEST_TARGET}/IsolatedNativeAuthTests"


def require_loopback_bindings():
    for service, port in (("kong", "55421"), ("db", "55422")):
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{json .NetworkSettings.Ports}}", f"supabase_{service}_{PROJECT_ID}"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise SystemExit(f"The W04 {service} container is unavailable.")
        try:
            ports = json.loads(result.stdout)
            bindings = [binding for entries in ports.values() if entries for binding in entries]
            if not any(binding["HostPort"] == port for binding in bindings) or any(
                binding["HostIp"] != "127.0.0.1" for binding in bindings
            ):
                raise SystemExit(f"The W04 {service} ports must be bound to 127.0.0.1 only.")
        except (json.JSONDecodeError, AttributeError, KeyError, TypeError):
            raise SystemExit(f"The W04 {service} port bindings could not be verified.") from None


def local_credentials(cli, stack_dir):
    config_root = stack_dir / "supabase"
    with (config_root / "config.toml").open("rb") as file:
        config = tomllib.load(file)
    if (
        config.get("project_id") != PROJECT_ID
        or config.get("api", {}).get("port") != 55421
        or config.get("auth", {}).get("sessions", {}).get("timebox") != "15s"
        or (config_root / ".temp" / "project-ref").exists()
    ):
        raise SystemExit("Expected only the dedicated, unlinked W04 Auth fixture project.")

    require_loopback_bindings()
    status = subprocess.run(
        [cli, "status", "--workdir", str(stack_dir), "--output", "json"],
        capture_output=True,
        text=True,
    )
    if status.returncode != 0:
        raise SystemExit("The local W04 stack is unavailable. Start the fixture first.")
    try:
        values = json.loads(status.stdout)
        public, admin = values["ANON_KEY"], values["SERVICE_ROLE_KEY"]
    except (json.JSONDecodeError, KeyError, TypeError):
        raise SystemExit("Expected local Supabase CLI v2 status and its legacy fixture keys.") from None
    if values.get("API_URL") != LOCAL_API or not isinstance(public, str) or not isinstance(admin, str) or not public or not admin:
        raise SystemExit("Expected fixture keys for the exact loopback endpoint.")
    return {
        "EXECUTE_ISOLATED_AUTH": "1",
        "EXECUTE_ISOLATED_AUTH_URL": LOCAL_API,
        "EXECUTE_ISOLATED_AUTH_PUBLIC_KEY": public,
        "EXECUTE_ISOLATED_AUTH_ADMIN_KEY": admin,
    }


def set_test_environment(run, credentials):
    if "TestConfigurations" in run:
        targets = [
            target for configuration in run["TestConfigurations"]
            for target in configuration.get("TestTargets", [])
            if target.get("BlueprintName") == TEST_TARGET
        ]
    else:
        targets = [target for name, target in run.items() if name == TEST_TARGET]
    if not targets:
        raise SystemExit("The xctestrun does not contain the ExecuteNativeTests target.")
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update(credentials)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-dir", required=True, type=Path)
    parser.add_argument("--xctestrun", required=True, type=Path)
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--cli", default="supabase-go")
    parser.add_argument("--result-bundle", type=Path)
    args = parser.parse_args()
    try:
        simulator_id = str(UUID(args.simulator_id))
    except ValueError:
        parser.error("--simulator-id must be a dedicated simulator UUID")

    credentials = local_credentials(args.cli, args.stack_dir.resolve())
    plan = args.xctestrun.resolve()
    with plan.open("rb") as file:
        run = plistlib.load(file)
    set_test_environment(run, credentials)

    # Keep __TESTROOT__ relative paths working. NamedTemporaryFile creates a mode 0600 plan.
    with tempfile.NamedTemporaryFile(prefix="execute-w04-", suffix=".xctestrun", dir=plan.parent) as plan_copy:
        plistlib.dump(run, plan_copy, fmt=plistlib.FMT_BINARY)
        plan_copy.flush()
        command = [
            "xcodebuild", "test-without-building", "-xctestrun", plan_copy.name,
            "-destination", f"platform=iOS Simulator,id={simulator_id.upper()}",
            "-parallel-testing-enabled", "NO", f"-only-testing:{TEST_CASE}",
        ]
        if args.result_bundle:
            command += ["-resultBundlePath", str(args.result_bundle.resolve())]
        environment = {key: value for key, value in os.environ.items() if not key.startswith("EXECUTE_ISOLATED_AUTH")}
        return subprocess.run(command, env=environment).returncode


if __name__ == "__main__":
    raise SystemExit(main())
