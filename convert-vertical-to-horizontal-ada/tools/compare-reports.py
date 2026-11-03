#!/usr/bin/env python3
"""Compare converter reports and ZIP contents; print aggregates, never book names."""
import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import zipfile


def native_path(value):
    """Allow a Windows reference report to be checked from WSL."""
    windows = PureWindowsPath(value)
    if windows.drive and windows.drive.endswith(":"):
        return Path("/mnt") / windows.drive[0].lower() / Path(*windows.parts[1:])
    return Path(value)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def compare(reference, actual, source):
    left = json.loads(reference.read_text(encoding="utf-8-sig"))
    right = json.loads(actual.read_text(encoding="utf-8-sig"))
    assert len(left) == len(right), "Report record count differs"
    assert len({item["Book"] for item in left}) == len(left), "Duplicate report identities"
    actual_by_name = {item["Book"]: item for item in right}
    assert len(actual_by_name) == len(right), "Duplicate actual report identities"
    entry_count = 0
    for index, expected in enumerate(left):
        observed = actual_by_name.get(expected["Book"])
        assert observed is not None, f"Record {index}: absent"
        for key in ("Status", "Reason", "ChangedEntries", "EntriesVerified", "InputBytes", "InputSHA256"):
            assert expected[key] == observed[key], f"Record {index}: {key} differs"
        assert observed["Status"] != "Error", f"Record {index}: conversion error"
        input_path = source if source.is_file() else source / expected["Book"]
        assert digest(input_path) == expected["InputSHA256"], f"Record {index}: source changed"
        assert input_path.stat().st_size == expected["InputBytes"], f"Record {index}: input size"
        for record in (expected, observed):
            output_path = native_path(record["Output"])
            assert digest(output_path) == record["OutputSHA256"], f"Record {index}: output hash"
            assert output_path.stat().st_size == record["OutputBytes"], f"Record {index}: output size"
            if record["Status"] == "Preserved":
                assert record["InputSHA256"] == record["OutputSHA256"], f"Record {index}: exact copy"
        with zipfile.ZipFile(native_path(expected["Output"])) as before, \
                zipfile.ZipFile(native_path(observed["Output"])) as after:
            x, y = before.infolist(), after.infolist()
            assert len(x) == len(y), f"Record {index}: entry count"
            for position, (old, new) in enumerate(zip(x, y)):
                for field in ("filename", "date_time", "external_attr", "file_size"):
                    assert getattr(old, field) == getattr(new, field), f"Record {index}, entry {position}: {field}"
                assert before.read(old) == after.read(new), f"Record {index}, entry {position}: payload"
                entry_count += 1
    return {"books": len(left), "entries": entry_count, "differences": 0}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.reference, args.actual, args.source)))
