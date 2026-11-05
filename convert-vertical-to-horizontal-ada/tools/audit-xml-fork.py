#!/usr/bin/env python3
"""Verify the maintained XML fork identity and its restricted project closure."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def source_files(root):
    return sorted(p for p in root.rglob("*") if p.is_file()
                  and not any(x in {"obj", "lib", "alire", "config", ".git"}
                              for x in p.relative_to(root).parts)
                  and p.name != "fork-identity.json")


def identity(root):
    files = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in source_files(root)}
    original = {x["Path"]: x["SHA256"].lower()
                for x in json.loads((root / "upstream-files.json").read_text())
                if not any(x in {"alire", "config"} for x in Path(x["Path"]).parts)}
    return {"Name": "xmlada_epub", "Version": "26.0.0-epub.1", "Files": files,
            "SourceSHA256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
            "Changed": sorted(p for p, h in files.items() if p in original and original[p] != h),
            "Added": sorted(set(files) - set(original)),
            "Removed": sorted(set(original) - set(files))}


def audit(project):
    visited = set()
    def visit(path):
        path = path.resolve()
        if path in visited:
            return
        visited.add(path)
        text = path.read_text()
        for name in re.findall(r'with\s+"([^"]+)"', text, re.I):
            if "xmlada" in name.lower():
                if not Path(name).name.startswith("xmlada_epub_"):
                    raise ValueError(f"Original XML/Ada import in {path}: {name}")
                if "dom" in name.lower() or "schema" in name.lower():
                    raise ValueError("DOM/schema entered the production profile")
            child = path.parent / name
            if child.exists():
                visit(child)
    visit(project / "epub_v2h_ada.gpr")
    for part in ("sax", "input", "unicode"):
        folder = {"input": "input_sources"}.get(part, part)
        visit(project / f"vendor/xmlada_epub/{folder}/xmlada_epub_{part}.gpr")
    for rel in ("alire.toml", "tests/alire.toml", "coverage/alire.toml"):
        text = (project / rel).read_text()
        if re.search(r'^xmlada\s*=', text, re.M) or 'xmlada_epub = "=26.0.0-epub.1"' not in text:
            raise ValueError(f"Wrong XML dependency in {rel}")
    selected = [project / "vendor/xmlada_epub" / part for part in ("sax", "input_sources", "unicode")]
    for folder in selected:
        for path in folder.glob("*.ad*"):
            if path.name.startswith("sax-pointers."):
                continue  # Excluded upstream generic; not in the supported profile.
            text = path.read_text(encoding="latin1")
            if re.search(r'\bGNAT\.Task_Lock\b|\bwith\s+Sax\.Pointers\b', text, re.I):
                raise ValueError(f"Shared XML ownership/lock in {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--sources-list", type=Path)
    parser.add_argument("--link-map", type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    root = project / "vendor/xmlada_epub"
    audit(project)
    if args.sources_list:
        sources = args.sources_list.read_text(encoding="utf-8-sig")
        xml_paths = [line.lower().replace("\\", "/") for line in sources.splitlines()
                     if re.search(r'[/\\](sax(?:-[\w]+)*|input_sources(?:-[\w]+)*|unicode(?:-[\w]+)*)\.ad[bs]$', line, re.I)]
        if not xml_paths or any("/vendor/xmlada_epub/" not in line for line in xml_paths):
            raise ValueError("Resolved XML unit outside the maintained fork")
    if args.link_map:
        linked = args.link_map.read_text(encoding="utf-8-sig").lower()
        if re.search(r'xmlada_26\.0\.0|sax__pointers__|epub__xml__(node_lists|attribute_lists)', linked):
            raise ValueError("Original XML ownership entered the linked production closure")
    current = identity(root)
    manifest = root / "fork-identity.json"
    if args.record:
        manifest.write_text(json.dumps(current, indent=2) + "\n")
    elif json.loads(manifest.read_text()) != current:
        raise ValueError("XML fork source identity changed; regenerate and review the patch manifest")
    print(json.dumps({k: v for k, v in current.items() if k != "Files"}, indent=2))


if __name__ == "__main__":
    main()
