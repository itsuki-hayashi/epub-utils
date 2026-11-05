#!/usr/bin/env python3
"""Validate source-bound, platform-specific GCC training data (Linux build helper)."""
import argparse
import hashlib
import json
from pathlib import Path


def identity(project, tuning, sections):
    sources = sorted([p for p in (project / "src").rglob("*")
                      if p.suffix in {".adb", ".ads", ".c"}] +
                     list(project.glob("*.gpr")) + [project / "alire.toml", project / "alire/alire.lock"] +
                     [p for p in (project / "vendor/xmlada_epub").rglob("*")
                      if p.is_file() and p.suffix in {".adb", ".ads", ".gpr", ".toml", ".json"}
                      and not any(part in {"obj", "lib", "alire", "config"} for part in p.relative_to(project / "vendor/xmlada_epub").parts)])
    hashes = "\n".join(p.relative_to(project).as_posix() + ":" +
                       hashlib.sha256(p.read_bytes()).hexdigest() for p in sources)
    return {"SourceSHA256": hashlib.sha256(hashes.encode()).hexdigest(),
            "CpuTuning": tuning, "SectionGC": sections, "Platform": "linux"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check-generate", "record", "check-use"))
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--tuning", choices=("native", "portable"), required=True)
    parser.add_argument("--sections", choices=("true", "false"), required=True)
    args = parser.parse_args()
    project, profile = args.project.resolve(), args.profile.resolve()
    if profile.is_relative_to(project.parent):
        raise ValueError("Keep private PGO data outside the repository")
    manifest = profile / "build-identity.json"
    current = identity(project, args.tuning, args.sections == "true")
    if args.mode == "check-generate":
        if manifest.exists():
            raise ValueError("Use a fresh profile directory for each training build")
        profile.mkdir(parents=True, exist_ok=True)
    elif args.mode == "record":
        with manifest.open("x") as stream:
            json.dump(current, stream, indent=2)
    else:
        if json.loads(manifest.read_text()) != current or not any(profile.rglob("*.gcda")):
            raise ValueError("PGO data is missing or belongs to different sources/configuration")


if __name__ == "__main__":
    main()
