# Linux x86-64

Linux and Windows share the Ada 2022 book, XML, archive, scanner, report, and
verified-publication core. GNAT 16.1.0, GPRbuild 26.0.1, XML/Ada 26.0.0, and
Zip-Ada 62.0.0 remain pinned. Platform adapters handle files and CP932 conversion.

## Build and run

Install Alire, `libc6-dev`, and `binutils` on Ubuntu. Then:

```sh
alr -n toolchain --select gnat_native=16.1.0 gprbuild=26.0.1
cd convert-vertical-to-horizontal-ada
sh tools/build.sh
bin/linux/epub-v2h --input-path /path/to/books --output-directory /path/to/output --json
```

The build prepares dependencies and builds only the application's dependency
closure. It does not build Zip-Ada's command-line programs. Owned Ada and C keep
strict warnings as errors; dependencies retain their upstream compiler flags.

The ELF executable is statically linked, including libc and compiler support.
It has no ELF interpreter or dynamic-library dependencies. No iconv modules,
locale files, XML/compression libraries, or Ada runtime files accompany it.

Linux publication uses `renameat2` with no replacement. Filesystems such as WSL's
`/mnt/c` that reject this flag use atomic hard-link creation, then remove the
temporary name. Both methods refuse any existing target, including a dangling
symlink. Filesystems supporting neither operation fail explicitly.

Linux paths and arguments use UTF-8. Recursive traversal skips directory symlinks.
A backslash is a literal filename character. Normal Linux filesystem case
sensitivity applies; exclusion of `horizontal` directories remains case-insensitive.

CP932 uses checked-in tables generated from strict Windows conversion APIs,
including private-use characters and canonical output choices. Linux does not
depend on a different system codec. Optional Windows regeneration uses
`tools/generate-cp932.ps1`. Shared tests check every single-byte code and lead-byte
pair, plus encoding throughout the supported BMP character range. Windows tests
compare the tables against the actual Windows APIs.

## Concurrency

Linux supports --jobs auto|N and --Jobs, with physical-core selection and
worker affinity readback. Missing core classes are disclosed under --verbose;
VMs expose their OS topology. See [CONCURRENCY.md](CONCURRENCY.md) for the shared
entry/book pool and publication ordering.

## Validation

```sh
sh tools/test.sh
python3 tools/test-linux-cli.py
```

Python 3 and `readelf` are development-only requirements. The shared AUnit suites
cover text, encoding, archives, classification, patches, book planning, and JSON.
Windows API fault injection remains Windows-only. The Linux CLI suite checks all
reference fixtures, ZIP payloads/metadata, exact-copy second passes, Unicode and
long paths, symlinks, recursion, simultaneous publication, overwrite protection,
temporary cleanup, dry runs, reports, malformed inputs, and static ELF linkage.
The executable is also run with runtime search paths removed.
Recorded build and public-fixture results are in
[`verification/linux-latest.json`](verification/linux-latest.json).

Repeat filesystem validation on a WSL Windows mount:

```sh
python3 tools/test-linux-cli.py --work-root /mnt/c/Users/USER/AppData/Local/Temp
```

`tools/compare-reports.py REFERENCE.json ACTUAL.json SOURCE` compares reports and
all ZIP entries independently. It translates Windows reference paths under WSL,
checks source immutability and reported hashes/sizes, and prints aggregates only.
Keep private reports and converted books outside the checkout.

Alire's default solver timeout may be short for a cold test workspace. If it
reports an incomplete solution, run `alr settings --set solver.timeout 120` and
`alr -n update` from `tests`, then retry. Do not accept missing dependencies or
disable checksum verification. SourceForge redirects sometimes serve HTML; the
official `downloads.sourceforge.net` archive endpoint can supply the same Zip-Ada
archive, which must match the pinned SHA-512 checksum.

## Sharing a checkout with Windows

Build from a separate Linux checkout or stage owned sources into Linux storage.
Alire's generated environment, lockfile platform origins, and dependency
configuration are host-specific. Do not run Windows and Linux Alire commands
concurrently in the same project directory. Object/binary directories are
separate, but Alire's generated state still needs isolation.

The resulting executable can read and write Windows-mounted paths directly;
input books do not need to be copied for execution.
