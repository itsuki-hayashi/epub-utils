# XML/Ada EPUB fork

Alire identity: `xmlada_epub=26.0.0-epub.1`. Upstream: AdaCore XML/Ada
26.0.0, https://github.com/AdaCore/xmlada/archive/refs/tags/v26.0.0.zip.
The Alire-verified archive SHA-512 is
`b140ed4a41210d9defccf07fde0eafe8ee3d883aa31bfc2996fab01409a657d11ea7af7f6caca2a5ffa492e5bd18ffb6958355c23aa78180f41a19af21efdd0f`.
`upstream-files.json` records the fetched source inventory. Alire cache metadata
is excluded from the maintained source identity. Original copyright headers,
COPYING3 and COPYING.RUNTIME remain intact.

The supported concurrent profile exports only `xmlada_epub_sax`,
`xmlada_epub_input`, and `xmlada_epub_unicode`. Original DOM/schema projects
remain upstream reference material and have no concurrency guarantee. Never
link original XML/Ada and this fork into the same executable.

Changes: task-owned symbol tables with borrowed plain handles replace global
task locking and controlled smart pointers; `Sax.Contexts` owns reader/table
lifetimes, task identity and generation checks; parser cleanup is idempotent;
closed string inputs cannot retain a dangling buffer. There is no shared
interner, atomic reference count, lazy global cache, or parser-wide lock.
Per-task context identity is thread-local. Unicode tables are immutable.
Reader buffers, attributes, DTD/entity models and namespace stacks are owned
by the reader adopted by one context. Arena records contain no controlled
components. The application stores only compact plain summary arrays.

Create, adopt one fresh reader, parse, then reset/close in the creating task.
The reader transfers to the context at adoption. Callback symbols are borrowed;
only `Contexts.Borrow`/`Contexts.Value` may export checked handles beyond a
callback. Reset invalidates all handles. Do not retain raw reader/symbol views
across reset, destruction or task boundaries. Release callbacks free extension
storage and must not raise exceptions. Context ownership and generation checks
execute with assertions disabled as well. All sizes use checked Ada arithmetic.

The fork keeps upstream optimization settings, bounds checks and assertions.
It does not inherit the application's additional warning policy. Objects and
libraries are separated by platform, role and build, with the existing GPR
subdirectory separating CPU/profiling configurations. No configure step, global
cache mutation, generated absolute path, or dependency source patch is needed.

Run `python3 tools/audit-xml-fork.py` from the application root to verify source
and patch identity and the restricted production project closure. Use
`--record` only when deliberately updating this maintained fork. The isolated
original-parser oracle is development tooling, never a converter dependency.
