"""Running external tools from verifiers."""

import shutil
import subprocess
from dataclasses import dataclass

from labcheck.paths import repo_root


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    @property
    def output(self) -> str:
        """Combined output, for assertion messages."""
        return (self.stdout + self.stderr).strip()


def tool_available(name: str) -> bool:
    return shutil.which(name) is not None


def run(args: list[str], cwd: str | None = None, timeout: int = 300) -> CommandResult:
    """Run a command from the repo root (or a subdirectory) and capture its output."""
    working_dir = repo_root() / cwd if cwd else repo_root()
    completed = subprocess.run(  # noqa: S603
        args,
        cwd=working_dir,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)
