# Isolated original parser oracle

`alr -n exec -- gprbuild -p -P oracle.gpr` in this directory links only the
original XML/Ada 26.0.0. `oracle_xml.*` is the frozen pre-fork application XML
collector, renamed without changing its parsing behavior. Build the fork summary
driver from the application Alire workspace with
`alr -n exec -- gprbuild -p -P tests/xml_oracle/summary.gpr`.
Never import both projects into one executable.

Run `tools/test-xml-differential.py --help` for the batch comparison. It compares
acceptance, owned entity diagnostics and all retained summary facts/flags,
including direct mixed-content text and qualified attribute names. Input files
and traces must be external to the repository. Full-book frozen-executable
comparisons additionally cover classification, changed entries, diagnostics,
compression and exact archive bytes. Neither driver is a converter dependency.
