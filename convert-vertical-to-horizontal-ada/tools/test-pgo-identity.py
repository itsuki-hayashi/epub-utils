#!/usr/bin/env python3
"""Ensure fork source, manifest and patch changes invalidate PGO training data."""
import importlib.util
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location("pgo_identity", Path(__file__).with_name("pgo-identity.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temporary:
    project = Path(temporary)
    for path in ("src/x.adb", "app.gpr", "alire.toml", "alire/alire.lock",
                 "vendor/xmlada_epub/sax/sax-contexts.adb", "vendor/xmlada_epub/alire.toml",
                 "vendor/xmlada_epub/sax/xmlada_epub_sax.gpr", "vendor/xmlada_epub/fork-identity.json"):
        file = project / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("original")
    for path in ("sax/sax-contexts.adb", "alire.toml", "sax/xmlada_epub_sax.gpr", "fork-identity.json"):
        before = module.identity(project, "native", True)
        file = project / "vendor/xmlada_epub" / path
        file.write_text("changed")
        assert module.identity(project, "native", True) != before, path
    before = module.identity(project, "native", True)
    generated = project / "vendor/xmlada_epub/sax/obj/windows/ignored.adb"
    generated.parent.mkdir(parents=True)
    generated.write_text("generated")
    assert module.identity(project, "native", True) == before
print("PGO fork source/manifest/project/patch invalidation: PASS")
