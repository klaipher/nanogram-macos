"""Throwaway git repositories for the core-bump tests (the parity gate itself is tested in shared/tests of klaipher/nanogram-deps)."""
import os
import subprocess
from pathlib import Path

OWNER_URL = "https://github.com/klaipher/example"


def run(repo, *args, env=None):
    full_env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                    GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com", **(env or {}))
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True, env=full_env).stdout.strip()


def init(repo):
    Path(repo).mkdir(parents=True, exist_ok=True)
    run(repo, "init", "-q", "-b", "main")
    run(repo, "config", "commit.gpgsign", "false")
    run(repo, "config", "protocol.file.allow", "always")


def commit(repo, files, message, date=None):
    for path, text in files.items():
        target = Path(repo) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        run(repo, "add", path)
    env = {"GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date} if date else None
    run(repo, "commit", "-q", "-m", message, env=env)
    return run(repo, "rev-parse", "HEAD")


def config_text(extra=""):
    return f"""
core submodules/telegram-ios
core-root ROOT
repo-root ios ROOT
mode shared
reference main
lag commits=2 days=7
pin tgcalls ios=submodules/TgVoipWebrtc/tgcalls mac=submodules/tgcalls
share submodules/Postbox
share submodules/TelegramCore
allow core submodules/Postbox/Mac.swift | Mac-only file
{extra}
"""
