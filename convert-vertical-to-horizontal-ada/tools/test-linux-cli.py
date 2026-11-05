#!/usr/bin/env python3
"""Linux CLI, filesystem, archive parity, and static-link acceptance checks."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def check(condition, description):
    if not condition:
        raise AssertionError(description)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main():
    project = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=project / "bin/linux/epub-v2h")
    parser.add_argument("--work-root", type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve()
    fixtures = project.parent / "convert-vertical-to-horizontal-perl/t/fixtures"
    manifest = json.loads((fixtures / "manifest.json").read_text())
    checked = 0

    def run(*arguments, cwd=None, clean_path=False):
        environment = dict(os.environ)
        if clean_path:
            environment["PATH"] = "/nonexistent"
            environment.pop("LD_LIBRARY_PATH", None)
            environment.pop("GCONV_PATH", None)
        return subprocess.run([str(executable), *map(str, arguments)], cwd=cwd,
                              env=environment, capture_output=True, text=True, encoding="utf-8")

    check(run("--help").returncode == 0, "Help")
    headers = subprocess.check_output(["readelf", "-l", str(executable)], text=True)
    dynamic = subprocess.check_output(["readelf", "-d", str(executable)], text=True)
    check("INTERP" not in headers and "NEEDED" not in dynamic, "Static ELF with no runtime libraries")
    with tempfile.TemporaryDirectory(prefix="epub-linux-cli-", dir=args.work_root) as temporary:
        root = Path(temporary)
        output, report = root / "output", root / "report.json"
        original = {item["Book"]: digest(fixtures / "input" / item["Book"]) for item in manifest}
        result = run("--input-path", fixtures / "input", "--output-directory", output,
                     "--report-path", report, "--json", clean_path=True)
        check(result.returncode == 0, "Fixture conversion")
        records = json.loads(result.stdout)
        check(records == json.loads(report.read_text()), "Stdout/report agreement")
        check(len(records) == len(manifest) == 21, "All fixtures processed")
        expected_by_name = {item["Book"]: item for item in manifest}
        check(sorted(item["Book"] for item in records) == sorted(expected_by_name), "Every queued fixture reports once")
        for actual in records:
            expected = expected_by_name[actual["Book"]]
            check(actual["Reason"] == expected["Reason"], "Fixture classification")
            check(actual["ChangedEntries"] == expected["ChangedEntries"], "Fixture patches")
            name = expected["Book"]
            check(actual["InputSHA256"] == original[name], "Input hash reporting")
            check(digest(fixtures / "input" / name) == original[name], "Source immutability")
            check(digest(output / name) == actual["OutputSHA256"], "Output hash reporting")
            check((output / name).stat().st_size == actual["OutputBytes"], "Output size reporting")
            if actual["Status"] == "Preserved":
                check(digest(output / name) == original[name], "Preserved exact copy")
            with zipfile.ZipFile(fixtures / "expected" / name) as before, zipfile.ZipFile(output / name) as after:
                old, new = before.infolist(), after.infolist()
                check(len(old) == len(new), "Entry count")
                for left, right in zip(old, new):
                    check((left.filename, left.date_time, left.external_attr) ==
                          (right.filename, right.date_time, right.external_attr), "Entry metadata and order")
                    check(before.read(left) == after.read(right), "Entry payload")
                    checked += 1
        second = root / "second"
        result = run("--input-path", output, "--output-directory", second, "--json")
        check(result.returncode == 0, "Second pass")
        for record in json.loads(result.stdout):
            check(record["Status"] == "Preserved", "Second pass preserves")
            check(digest(output / record["Book"]) == digest(second / record["Book"]), "Second pass exact copy")
        preview = root / "preview"
        result = run("--InputPath", fixtures / "input", "--OutputDirectory", preview,
                     "--WhatIf", "--ReportPath", root / "preview.json", "--json")
        check(result.returncode == 0 and not preview.exists() and not (root / "preview.json").exists(),
              "Dry run creates no files or directories")
        check(all(item["Status"] == "WhatIf" for item in json.loads(result.stdout)), "Dry run statuses")
        check(run("--input-path", fixtures / "input", "--analyze-only", "--report-path", report).returncode == 1,
              "Report collision protection")
        check(run("--input-path", fixtures / "input", "--output-directory", output).returncode == 1,
              "Book collision protection")
        preserved = next(item["Book"] for item in manifest if item["Reason"] == "Horizontal")
        sample = fixtures / "input" / preserved
        tree = root / "日本語-😀"
        child = tree / ("long-path-" * 15) / ("nested-" * 20)
        child.mkdir(parents=True)
        shutil.copyfile(sample, tree / "a.epub")
        shutil.copyfile(sample, child / "b.epub")
        excluded = tree / "HoRiZoNtAl"
        excluded.mkdir()
        shutil.copyfile(sample, excluded / "skip.epub")
        (tree / "directory-link").symlink_to(child, target_is_directory=True)
        result = run("--input-path", tree, "--recursive", "--json")
        check(result.returncode == 0 and len(json.loads(result.stdout)) == 2,
              "Recursive Unicode/long paths, output exclusion, and directory symlink skipping")
        literal = root / "literal\\name.epub"
        shutil.copyfile(sample, literal)
        check(run("--input-path", literal, "--output-directory", root / "literal-output").returncode == 0,
              "Backslash is a literal Linux filename character")
        defaults = root / "defaults"
        defaults.mkdir()
        shutil.copyfile(sample, defaults / "default.epub")
        check(run("--json", cwd=defaults).returncode == 0 and (defaults / "horizontal/default.epub").exists(),
              "Default current directory")
        mixed = root / "mixed"
        mixed.mkdir()
        (mixed / "a-bad.epub").write_bytes(b"not a ZIP")
        shutil.copyfile(sample, mixed / "z-good.epub")
        result = run("--input-path", mixed, "--output-directory", root / "mixed-output", "--json")
        check(result.returncode == 1 and sorted(item["Status"] for item in json.loads(result.stdout)) ==
              ["Error", "Preserved"], "Per-book failure isolation")
        dangling = root / "dangling"
        dangling.mkdir()
        (dangling / preserved).symlink_to(root / "absent-target")
        check(run("--input-path", sample, "--output-directory", dangling).returncode == 1 and
              (dangling / preserved).is_symlink(), "Dangling destination symlink is never replaced")
        race = root / "race"
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(run, "--input-path", sample, "--output-directory", race, "--json")
                    for _ in range(2)]
        check(sorted(job.result().returncode for job in jobs) == [0, 1], "Concurrent publishers refuse replacement")
        check(digest(race / preserved) == digest(sample), "Published race winner is complete")
        check(not list(root.rglob(".epub-horizontal-*.tmp")), "Temporary output cleanup")
        for arguments in [("--unknown",), ("--input-path",), ("unexpected",)]:
            check(run(*arguments).returncode == 1, "CLI invalid arguments")
        for jobs in ("1", "2", "auto"):
            parallel = root / ("jobs-" + jobs)
            result = run("--input-path", fixtures / "input", "--output-directory", parallel, "--Jobs", jobs, "--json")
            check(result.returncode == 0, "Worker mode " + jobs)
            for record in json.loads(result.stdout):
                check(digest(output / record["Book"]) == digest(parallel / record["Book"]), "Worker byte identity")
        for jobs in ("0", "-1", "invalid", "999999"):
            check(run("--input-path", sample, "--analyze-only", "--jobs", jobs).returncode == 1,
                  "Invalid worker count rejected")
    print(json.dumps({"fixtures": len(manifest), "entries": checked, "filesystem_and_cli": "PASS", "static_elf": "PASS"}))


if __name__ == "__main__":
    main()
