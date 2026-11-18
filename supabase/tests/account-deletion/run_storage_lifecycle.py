#!/usr/bin/env python3
"""Run W09's Auth and Storage lifecycle on the verified disposable W04 stack."""

import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
fixture_runner = Path(__file__).resolve().parent.parent / "native-auth"
sys.path.insert(0, str(fixture_runner))
from run import LOCAL_API, local_credentials


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack-dir", type=Path, required=True)
    parser.add_argument("--cli", default="supabase-go")
    parser.add_argument("--deno", default="deno")
    args = parser.parse_args()

    credentials = local_credentials(args.cli, args.stack_dir.resolve())
    runner = Path(__file__).resolve().with_name("storage-lifecycle.ts")
    env = dict(os.environ, **credentials)
    return subprocess.run(
        [
            args.deno,
            "run",
            "--cached-only",
            "--no-lock",
            "--no-prompt",
            f"--allow-net={LOCAL_API.removeprefix('http://')}",
            f"--allow-env={','.join(credentials)}",
            str(runner),
        ],
        env=env,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
