#!/usr/bin/env python3
"""Install, reset, and compare lab starter files.

Starter files live at their *real* path -- ``.github/workflows/``, ``infra/``,
``k8s/`` -- because that is the only place the tools that read them will look.
``labs/NN_*/starter/`` holds pristine copies so ``reset`` can restore them, and
``labs/NN_*/solution/`` holds the reference answer to diff against.

Each lab describes its own file mapping in ``labs/NN_*/lab.yml``.
"""

import argparse
import difflib
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
LABS_DIR = REPO_ROOT / "labs"


class LabError(Exception):
    """Something the user can fix, reported without a traceback."""


@dataclass(frozen=True)
class LabFile:
    starter: Path
    target: Path
    solution: Path | None


@dataclass(frozen=True)
class Lab:
    slug: str
    title: str
    project: int
    directory: Path
    files: list[LabFile]

    @property
    def number(self) -> str:
        return self.slug.split("_", 1)[0]

    @property
    def readme(self) -> Path:
        return self.directory / "README.md"


def find_lab(identifier: str) -> Lab:
    """Resolve '1', '01', or a full slug to a lab directory."""
    normalized = identifier.strip().lstrip("0") or "0"
    matches = sorted(
        d
        for d in LABS_DIR.iterdir()
        if d.is_dir() and (d.name == identifier or d.name.split("_", 1)[0].lstrip("0") == normalized)
    )
    if not matches:
        available = ", ".join(sorted(d.name for d in LABS_DIR.iterdir() if d.is_dir()))
        raise LabError(f"no lab matches {identifier!r}\n  available: {available or '(none yet)'}")
    return load_lab(matches[0])


def load_lab(directory: Path) -> Lab:
    manifest_path = directory / "lab.yml"
    if not manifest_path.is_file():
        raise LabError(f"{directory.name} has no lab.yml manifest")

    manifest = yaml.safe_load(manifest_path.read_text()) or {}
    files = []
    for entry in manifest.get("files", []):
        solution = entry.get("solution")
        files.append(
            LabFile(
                starter=directory / entry["starter"],
                target=REPO_ROOT / entry["target"],
                solution=directory / solution if solution else None,
            )
        )
    return Lab(
        slug=directory.name,
        title=manifest.get("title", directory.name),
        project=int(manifest.get("project", 0)),
        directory=directory,
        files=files,
    )


def install(lab: Lab, *, force: bool) -> int:
    """Copy starter files to their real paths, refusing to clobber your work."""
    for spec in lab.files:
        if not spec.starter.is_file():
            raise LabError(f"starter file missing: {spec.starter.relative_to(REPO_ROOT)}")

        rel = spec.target.relative_to(REPO_ROOT)
        if spec.target.exists() and not force:
            if spec.target.read_text() == spec.starter.read_text():
                print(f"  = {rel} (already the starter)")
            else:
                print(f"  ! {rel} exists and differs -- keeping your version")
                print("      use 'make reset LAB=%s' to discard it" % lab.number)
            continue

        spec.target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(spec.starter, spec.target)
        print(f"  + {rel}")
    return 0


def reset(lab: Lab) -> int:
    print(f"Resetting Lab {lab.number} -- {lab.title}")
    return install(lab, force=True)


def show_solution(lab: Lab) -> int:
    """Unified diff from your current file to the reference solution."""
    shown = 0
    for spec in lab.files:
        if spec.solution is None or not spec.solution.is_file():
            continue
        rel = spec.target.relative_to(REPO_ROOT)
        current = spec.target.read_text().splitlines(keepends=True) if spec.target.is_file() else []
        reference = spec.solution.read_text().splitlines(keepends=True)

        diff = list(
            difflib.unified_diff(current, reference, fromfile=f"yours/{rel}", tofile=f"solution/{rel}")
        )
        shown += 1
        if not diff:
            print(f"\n{rel}: identical to the solution.")
            continue
        print(f"\n{rel}:")
        sys.stdout.writelines(diff)

    if shown == 0:
        raise LabError(f"Lab {lab.number} has no solution files")
    return 0


def status() -> int:
    """One line per lab: which files are installed, and whether they were edited."""
    directories = sorted(d for d in LABS_DIR.iterdir() if d.is_dir() and (d / "lab.yml").is_file())
    if not directories:
        print("No labs built yet.")
        return 0

    for directory in directories:
        lab = load_lab(directory)
        states = []
        for spec in lab.files:
            if not spec.target.exists():
                states.append("not installed")
            elif spec.starter.is_file() and spec.target.read_text() == spec.starter.read_text():
                states.append("untouched starter")
            else:
                states.append("edited")
        summary = ", ".join(sorted(set(states))) or "no files"
        print(f"  Lab {lab.number}  {lab.title:<42} {summary}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="labctl", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    for name in ("install", "reset", "solution", "readme"):
        p = sub.add_parser(name)
        p.add_argument("lab")
        if name == "install":
            p.add_argument("--force", action="store_true")

    sub.add_parser("status")

    args = parser.parse_args()

    try:
        if args.command == "status":
            return status()

        lab = find_lab(args.lab)
        if args.command == "install":
            print(f"Lab {lab.number} -- {lab.title}")
            return install(lab, force=args.force)
        if args.command == "reset":
            return reset(lab)
        if args.command == "solution":
            return show_solution(lab)
        if args.command == "readme":
            print(lab.readme)
            return 0
    except LabError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
