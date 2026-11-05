#!/usr/bin/env python3
"""Compare isolated original XML trees with context-owned compact SAX summaries.

All decoded documents and parser traces are written to an external artifact root.
Drivers read many requests in one test-only process each; the converter never
starts these helpers. Run with Windows drivers under WSL or native Linux drivers.
"""
import argparse
import json
import random
import re
import subprocess
import zipfile
from pathlib import Path

FIELDS = ("full-path", "name", "property", "content", "properties", "id", "href",
          "media-type", "idref", "class", "rel")
KINDS = dict(zip(("rootfile", "meta", "manifest", "item", "spine", "itemref", "body", "svg",
                 "script", "style", "title", "desc", "img", "image", "link"),
                ("ROOTFILE", "META", "MANIFEST", "MANIFEST_ITEM", "SPINE", "SPINE_ITEM", "BODY_ELEMENT", "SVG",
                 "SCRIPT_ELEMENT", "STYLE_ELEMENT", "TITLE", "DESCRIPTION", "IMAGE", "IMAGE", "LINK")))


def windows_path(path):
    text = str(path.resolve())
    return text[5].upper() + ":\\" + text[7:].replace("/", "\\") if text.startswith("/mnt/") else text


def batch(exe, requests, trace):
    result = subprocess.run([str(exe.resolve())], input="\n".join(requests) + "\n",
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    trace.write_text(result.stdout)
    if result.returncode or result.stderr:
        raise AssertionError(result.stderr)
    chunks, rows = [], []
    for line in result.stdout.splitlines():
        if line == ".":
            chunks.append(rows)
            rows = []
        else:
            rows.append(line)
    assert not rows and len(chunks) == len(requests)
    return chunks


def expected(rows, mode):
    if rows[0].startswith("ERR:"):
        return None
    nodes = []
    for row in rows[1:]:
        parent, name, content, *attrs = row.split("\t")
        nodes.append((int(parent), bytes.fromhex(name).decode(), bytes.fromhex(content),
                      dict(tuple(bytes.fromhex(x).decode() for x in attr.split("=")) for attr in attrs)))
    facts, visible, images, fixed = [], False, False, False
    for index, (parent, name, content, attrs) in enumerate(nodes):
        kind = KINDS.get(name, "OTHER_ELEMENT")
        parent_kind = KINDS.get(nodes[parent-1][1], "OTHER_ELEMENT") if parent else "OTHER_ELEMENT"
        ancestry, cursor = [index], parent
        while cursor:
            ancestry.append(cursor - 1)
            cursor = nodes[cursor - 1][0]
        names = [nodes[x][1] for x in ancestry]
        if ("body" in names or (nodes[0][1] == "svg")) and not any(x in names for x in ("script", "style", "title", "desc")):
            visible |= bool(content.strip(b" \t\n\r\v\f"))
        images |= kind == "IMAGE"
        keep = (kind == "ROOTFILE" if mode == "C" else kind in ("META", "MANIFEST_ITEM", "SPINE_ITEM") if mode == "P" else
                bool(attrs.get("id") or attrs.get("class") or (kind == "LINK" and "stylesheet" in attrs.get("rel", "").lower().split())))
        if not keep:
            continue
        fields = [attrs.get(field, "") if (field == "full-path" if mode == "C" else field not in ("class", "rel") if mode == "P" else
                  field in ("id", "class") or (kind == "LINK" and field in ("href", "rel"))) else "" for field in FIELDS]
        facts.append([kind, parent_kind, content.hex() if kind == "META" else ""] + [x.encode().hex() for x in fields])
        if mode == "P":
            fixed |= (kind == "META" and ((attrs.get("property") == "rendition:layout" and content.strip(b" ") == b"pre-paginated") or
                      (attrs.get("name") == "fixed-layout" and attrs.get("content") == "true"))) or (
                          kind == "SPINE_ITEM" and "rendition:layout-pre-paginated" in attrs.get("properties", "").split())
    return [[str(x).upper() for x in (visible, images, fixed)]] + facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    root = args.artifacts.resolve()
    project = Path(__file__).resolve().parent.parent.parent
    assert not root.is_relative_to(project), "Private oracle data must remain outside the repository"
    root.mkdir(parents=True, exist_ok=True)
    documents = [b"<root/>", b"<a><b></a>", b"<a x='1' x='2'/>", b"<a xmlns:p='u' p:x='1' x='2'/>",
                 b"<a xmlns:p='u' xmlns:q='u' p:x='1' q:x='2'/>", b"<a>&unknown;</a>",
                 b"<!DOCTYPE a [<!ENTITY x 'v'>]><a>&x;</a>", b"<!DOCTYPE a SYSTEM 'file:///never-read'><a/>",
                 b"<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///never-read'>]><a/>", b"<a><!--x--><![CDATA[text]]><?pi x?></a>",
                 b"<package><meta property='rendition:layout'>pre-<b>wrong</b>paginated</meta></package>",
                 b"<svg><title>hidden</title><desc>hidden</desc><text>visible</text></svg>",
                 b"<html><body><script>hidden</script><style>hidden</style><title>hidden</title><p>&#x20;</p></body></html>",
                 b"<a>" + b"x" * 131073 + b"</a>", b"<a>" * 1000 + b"visible" + b"</a>" * 1000,
                 b"<a " + b" ".join((f"a{i}='v'".encode() for i in range(1000))) + b"/>",
                 b"<a/><!--bad--->", b"<a>&#0;</a>", b"<?xml version='1.1'?><a/>"]
    rng = random.Random(74411)
    for _ in range(200):
        name = rng.choice(("meta", "item", "itemref", "rootfile", "p", "img", "link"))
        attrs = " ".join(f"{field}='{rng.choice(('x', 'stylesheet', 'vertical', '', 'rendition:layout-pre-paginated'))}'"
                         for field in rng.sample(FIELDS, rng.randrange(5)))
        documents.append(f"<html xmlns:p='urn:p'><body><{name} {attrs}>a<b/>b<![CDATA[c]]>&amp;d</{name}></body></html>".encode())
    skipped = 0
    for book in sorted(args.corpus.rglob("*.epub")):
        with zipfile.ZipFile(book) as archive:
            for entry in archive.infolist():
                if Path(entry.filename).suffix.lower() not in {".xml", ".opf", ".xhtml", ".html", ".svg", ".ncx"}:
                    continue
                data = archive.read(entry)
                match = re.search(br"encoding\s*=\s*['\"]([^'\"]+)", data[:300])
                encoding = (match[1].decode() if match else "utf-8-sig")
                if encoding.lower() in {"shift_jis", "shift-jis", "sjis"}:
                    encoding = "cp932"
                try:
                    documents.append(data.decode(encoding).encode())
                except (UnicodeError, LookupError):
                    skipped += 1
    paths = []
    for index, document in enumerate(documents):
        path = root / f"document-{index}.xml"
        path.write_bytes(document)
        paths.append(windows_path(path) if args.oracle.suffix == ".exe" else str(path))
    originals = batch(args.oracle, paths, root / "original.trace")
    summaries = batch(args.summary, [mode + path for path in paths for mode in "CPT"], root / "summary.trace")
    accepted, rejected = 0, 0
    for index, original in enumerate(originals):
        for offset, mode in enumerate("CPT"):
            want = expected(original, mode)
            got = summaries[3 * index + offset]
            if want is None:
                assert got[0].startswith("ERR:"), (index, mode, "acceptance mismatch")
                for message in ("XML entity declarations require manual review", "External XML entity declarations are unsupported", "External XML resources are unsupported"):
                    if bytes.fromhex(original[0][4:]).decode() == message:
                        assert original[0] == got[0], (index, mode, "owned diagnostic changed")
            else:
                assert got[0] == "OK", (index, mode, got)
                actual = [row.split("\t") for row in got[1:]]
                assert want == actual, (index, mode, "summary mismatch", want[:3], actual[:3])
        if original[0] == "OK": accepted += 1
        else: rejected += 1
    result = dict(documents=len(documents), comparisons=3 * len(documents), accepted=accepted, rejected=rejected,
                  undecodable_resources_skipped=skipped, result="PASS")
    (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
