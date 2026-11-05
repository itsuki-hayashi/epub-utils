# Compiler and dependency policy

The user's revised scope applies strict diagnostics to code owned by this
project. Application code, reusable owned containers, tests, proof units and
native helpers retain all optional GNAT warnings as errors, Ada 2022,
applicable backend warnings as errors, runtime checks and validation assertions.

XML/Ada, Zip-Ada, AUnit and other third-party code use their upstream project
settings. We do not inject `-Wall`, `-Wextra`, `-Werror`, `-gnatw.e` or `-gnatwe`
into dependency builds. Dependency diagnostics do not form a release gate.
Compilation failures and behavioral failures remain errors. Static linkage,
dependency pins, import audits, application coverage and core proof gates remain
required.

Production uses the maintained `xmlada_epub=26.0.0-epub.1` SAX/input/Unicode
fork, pinned by relative path in the application, tests and coverage manifests.
This is the explicitly approved dependency-source exception for task-owned
XML parsing. It is not a warning-cleanup fork. Bounds checks and assertions
remain enabled; ownership checks are executable code, independent of assertions.
Original XML/Ada is restricted to the separately linked test oracle. DOM and
schema are not exported by the production profile and are not concurrency-safe
interfaces. See [fork provenance](vendor/xmlada_epub/EPUB_FORK.md).
Zip-Ada and all other dependencies remain unmodified at their existing versions.

Test-only JSON sources are also unmodified. `tests/json_dependency.gpr` supplies
the compatible build configuration: the upstream No_Implementation_Extensions
profile contradicts the crate's own SPARK_Mode aspects on GNAT 16, so the
remaining No_Obsolescent_Features restriction is applied separately. This is a
project configuration adjustment, not a source patch.

The JSON generic instances are compiled in that dependency project; owned test
logic imports them with strict diagnostics. JSON 6.0.0's string unescaper has
Unicode limitations. Raw JSON byte checks and the independent PowerShell CLI
tests verify Unicode output without modifying the library.

GNATcoverage-generated support code uses its tool-provided configuration.
Normal application and unit-test builds establish the strict owned-source
warning gate before instrumentation. Generated and third-party code are
reported separately from owned application coverage.
