#!/usr/bin/env python3
"""Measure Linux Ada alone; verify against an existing Windows Perl report.

Prepare inputs/reference paths before measurement. Artifacts must be outside the
checkout. This makes no Windows-versus-Linux or Perl speedup claim.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time
import uuid
import zipfile


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def validate(expected, actual, inputs):
    assert len(actual) == len(expected), "Incomplete report"
    reference = {row["Book"]: row for row in expected}
    before_total = after_total = larger = 0
    for row in actual:
        old = reference[row["Book"]]
        assert row["Status"] != "Error", "Conversion failed"
        for key in ("Status", "Reason", "InputBytes", "InputSHA256",
                    "EntriesVerified", "ChangedEntries"):
            assert row[key] == old[key], f"Report mismatch: {key}"
        assert digest(inputs / row["Book"]) == old["InputSHA256"], "Source changed"
        for item in (old, row):
            assert digest(item["Output"]) == item["OutputSHA256"], "Output hash"
            assert Path(item["Output"]).stat().st_size == item["OutputBytes"], "Output size"
            if item["Status"] == "Preserved":
                assert item["InputSHA256"] == item["OutputSHA256"], "Exact copy"
        with zipfile.ZipFile(old["Output"]) as left, zipfile.ZipFile(row["Output"]) as right:
            a, b = left.infolist(), right.infolist()
            assert len(a) == len(b), "Entry count"
            for x, y in zip(a, b):
                assert (x.filename, x.date_time, x.external_attr) == (
                    y.filename, y.date_time, y.external_attr), "Entry metadata/order"
                assert left.read(x) == right.read(y), "Entry payload/CRC"
            before = sum(x.compress_size for x in a)
            after = sum(x.compress_size for x in b)
            before_total += before
            after_total += after
            larger += after > before
    assert after_total <= before_total, "Aggregate compression quality"
    return {"compressed_expected": before_total, "compressed_actual": after_total,
            "larger_books": larger}


def main():
    if not __debug__:
        raise RuntimeError("Run without Python -O/PYTHONOPTIMIZE; validation uses assertions")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--reference-report", type=Path, required=True,
                        help="Windows Perl report with paths adapted to Linux")
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=8)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    checkout = Path(__file__).resolve().parents[1]
    root = args.work_root.resolve()
    if root.is_relative_to(checkout):
        parser.error("Keep private measurement artifacts outside the checkout")
    executable = args.executable.resolve()
    identity = digest(executable)
    expected = json.loads(args.reference_report.read_text(encoding="utf-8-sig"))
    if not expected or any(row["Status"] == "Error" for row in expected):
        raise ValueError("A nonempty successful Windows Perl reference is required")
    directory = root / ("linux-measurement-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    cpu = min(os.sched_getaffinity(0))
    rows = []
    for index in range(-1, args.runs):
        run = directory / ("warmup" if index < 0 else f"run-{index}")
        run.mkdir()
        report = run / "report.json"
        with report.open("wb") as stdout, (run / "stderr.log").open("wb") as stderr:
            started = time.perf_counter()
            result = subprocess.run([
                "/usr/bin/time", "-f", "%U %S %M", "-o", str(run / "resources.txt"),
                "taskset", "-c", str(cpu), str(executable),
                "--input-path", str(args.input.resolve()),
                "--output-directory", str(run / "books"), "--json"],
                stdout=stdout, stderr=stderr, cwd=run, check=False)
            elapsed = time.perf_counter() - started
        if result.returncode:
            raise RuntimeError("Conversion failed; private diagnostics retained")
        quality = validate(expected, json.loads(report.read_text()), args.input.resolve())
        user, system, peak = (run / "resources.txt").read_text().split()
        row = {"Seconds": elapsed, "CPUSeconds": float(user) + float(system),
               "PeakRSSBytes": int(peak) * 1024, "Quality": quality}
        if index >= 0:
            rows.append(row)
            (directory / "runs.json").write_text(json.dumps(rows, indent=2))
        print(f"Validated Linux {'warmup' if index < 0 else index + 1}: {elapsed:.3f}s", flush=True)
    assert digest(executable) == identity, "Executable changed during measurement"
    summary = {"Platform": "Linux", "PerlSpeedupClaim": False, "Books": len(expected),
               "Runs": args.runs, "CPU": cpu, "BinarySHA256": identity,
               "BinaryBytes": executable.stat().st_size,
               "MedianSeconds": statistics.median(row["Seconds"] for row in rows),
               "MedianCPUSeconds": statistics.median(row["CPUSeconds"] for row in rows),
               "MedianPeakRSSBytes": statistics.median(row["PeakRSSBytes"] for row in rows)}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
