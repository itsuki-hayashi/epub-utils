#!/usr/bin/env python3
"""Measure Linux Ada alone; verify against an existing Windows Perl report.

Prepare inputs/reference paths before measurement. Artifacts must be outside the
checkout. This makes no Windows-versus-Linux or Perl speedup claim.
"""
import argparse
import csv
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
    assert len(reference) == len(expected), "Duplicate reference book"
    seen = set()
    before_total = after_total = larger = 0
    growth = []
    for row in actual:
        assert row["Book"] not in seen, "Duplicate actual book"
        seen.add(row["Book"])
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
            if after > before:
                growth.append({"book": row["Book"], "compressed_expected": before,
                               "compressed_actual": after, "delta": after - before})
    assert after_total <= before_total, "Aggregate compression quality"
    return {"compressed_expected": before_total, "compressed_actual": after_total,
            "larger_books": larger, "growth": growth}


def main():
    if not __debug__:
        raise RuntimeError("Run without Python -O/PYTHONOPTIMIZE; validation uses assertions")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--reference-report", type=Path, required=True,
                        help="Windows Perl report with paths adapted to Linux")
    parser.add_argument("--quality-baseline-report", type=Path,
                        help="Frozen Ada report with paths adapted to Linux")
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=8)
    parser.add_argument("--jobs", help="auto or a positive count; omit for older executables")
    parser.add_argument("--affinity-mode", choices=("SingleCore", "PhysicalCores"), default="SingleCore")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.jobs is not None and args.jobs != "auto" and (
            not args.jobs.isascii() or not args.jobs.isdecimal() or int(args.jobs) < 1):
        parser.error("--jobs requires auto or a positive integer")
    checkout = Path(__file__).resolve().parents[2]
    root = args.work_root.resolve()
    if root.is_relative_to(checkout):
        parser.error("Keep private measurement artifacts outside the checkout")
    executable = args.executable.resolve()
    identity = digest(executable)
    expected = json.loads(args.reference_report.read_text(encoding="utf-8-sig"))
    baseline_identity = digest(args.quality_baseline_report) if args.quality_baseline_report else None
    baseline = (json.loads(args.quality_baseline_report.read_text(encoding="utf-8-sig"))
                if args.quality_baseline_report else None)
    if baseline is not None:
        by_book = {row["Book"]: row for row in baseline}
        if len(by_book) != len(baseline):
            raise ValueError("Duplicate quality baseline book")
        baseline = [by_book[row["Book"]] for row in expected]
    if args.runs >= 8 and baseline is None:
        parser.error("Full measurements require --quality-baseline-report")
    if not expected or any(row["Status"] == "Error" for row in expected):
        raise ValueError("A nonempty successful Windows Perl reference is required")
    directory = root / ("linux-measurement-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    allowed = sorted(os.sched_getaffinity(0))
    affinity = allowed if args.affinity_mode == "PhysicalCores" else allowed[:1]
    rows = []
    for index in range(-1, args.runs):
        run = directory / ("warmup" if index < 0 else f"run-{index}")
        run.mkdir()
        report = run / "report.json"
        with report.open("wb") as stdout, (run / "stderr.log").open("wb") as stderr:
            started = time.perf_counter()
            result = subprocess.run([
                "/usr/bin/time", "-f", "%U %S %M", "-o", str(run / "resources.txt"),
                "taskset", "-c", ",".join(map(str, affinity)), str(executable),
                "--input-path", str(args.input.resolve()),
                "--output-directory", str(run / "books"), "--json"] +
                (["--jobs", args.jobs] if args.jobs is not None else []),
                stdout=stdout, stderr=stderr, cwd=run, check=False,
                env=dict(os.environ, EPUB_CONCURRENCY_STATS=str(run / "workers.csv")))
            elapsed = time.perf_counter() - started
        if result.returncode:
            raise RuntimeError("Conversion failed; private diagnostics retained")
        quality = validate(expected, json.loads(report.read_text()), args.input.resolve())
        baseline_quality = (validate(baseline, json.loads(report.read_text()), args.input.resolve())
                            if baseline is not None else None)
        user, system, peak = (run / "resources.txt").read_text().split()
        workers = 1
        if (run / "workers.csv").exists():
            with (run / "workers.csv").open() as stream:
                for stat in csv.DictReader(stream):
                    if stat["Metric"] == "workers":
                        workers = int(stat["Value"])
        row = {"Seconds": elapsed, "CPUSeconds": float(user) + float(system),
               "Workers": workers, "WorkerUtilization": (float(user) + float(system)) / (elapsed * workers),
               "PeakRSSBytes": int(peak) * 1024, "Quality": quality,
               "BaselineQuality": baseline_quality}
        if index >= 0:
            rows.append(row)
            (directory / "runs.json").write_text(json.dumps(rows, indent=2))
        print(f"Validated Linux {'warmup' if index < 0 else index + 1}: {elapsed:.3f}s", flush=True)
    assert digest(executable) == identity, "Executable changed during measurement"
    if baseline_identity is not None:
        assert digest(args.quality_baseline_report) == baseline_identity, "Quality baseline changed"
    summary = {"ArtifactDirectory": str(directory), "Platform": "Linux", "PerlSpeedupClaim": False, "Books": len(expected),
               "Runs": args.runs, "Affinity": affinity, "AffinityMode": args.affinity_mode,
               "Jobs": args.jobs, "BinarySHA256": identity,
               "DualCompressionGate": baseline is not None,
               "BinaryBytes": executable.stat().st_size,
               "MedianSeconds": statistics.median(row["Seconds"] for row in rows),
               "MedianCPUSeconds": statistics.median(row["CPUSeconds"] for row in rows),
               "MedianPeakRSSBytes": statistics.median(row["PeakRSSBytes"] for row in rows),
               "MaxPeakRSSBytes": max(row["PeakRSSBytes"] for row in rows)}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
