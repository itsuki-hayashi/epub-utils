# Compiler and dependency policy

The user's revised scope applies strict diagnostics to code owned by this
project. Application code, reusable owned containers, tests, proof units and
native test helpers retain all optional GNAT warnings as errors, Ada 2022,
applicable backend warnings as errors, runtime checks and validation assertions.

XML/Ada, Zip-Ada, AUnit and other third-party code use their upstream project
settings. We do not inject `-Wall`, `-Wextra`, `-Werror`, `-gnatw.e` or `-gnatwe`
into dependency builds. Dependency diagnostics do not form a release gate.
Compilation failures and behavioral failures remain errors. Static linkage,
dependency pins, import audits, application coverage and core proof gates remain
required.

Production uses the original pinned Alire XML/Ada and Zip-Ada projects. All
experimental dependency source patches, vendor copies, patch generators and
warning-cleanup projects have been removed.

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
