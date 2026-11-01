# Dependency source provenance

CPAN modules are installed into `local/` according to `cpanfile`, using
`tools/install-dependencies.pl`. These original source archives support the
native Windows bootstrap; each retains its upstream license files. No archive
has been modified. The installer verifies their SHA-256 before use.

| Archive | Original source | SHA-256 |
| --- | --- | --- |
| `PkgConfig-0.26026.tar.gz` | [CPAN distribution](https://cpan.metacpan.org/authors/id/P/PL/PLICEASE/PkgConfig-0.26026.tar.gz) | `5352ed156a4b5de8c523771ee399f6f8ce5e8bfcf8674f1e1dbd4a8c83643b85` |
| `Module-Pluggable-6.3.tar.gz` | [CPAN distribution](https://cpan.metacpan.org/authors/id/S/SI/SIMONW/Module-Pluggable-6.3.tar.gz) | `58512bb9c654746d0937770b98b559b30872d85ac24073485e5830890dd1b2a0` |
| `libxml2-2.15.4.tar.xz` | [GNOME distribution](https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz) | `98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821` |

`tools/cpanm` is the self-contained [cpanminus bootstrap](https://github.com/miyagawa/cpanminus),
downloaded from the project's `master/cpanm` file. Its SHA-256 is
`137e8c5856e09867f6d7631d6d67a5e7778166962e29830c573cbbbab6ed2e21`.
The bootstrap retains its upstream licensing material and is excluded from
owned-source Perl::Tidy/Perl::Critic checks.

## Windows build accommodations

- PkgConfig's original test uses `eval { symlink("", ""); 1 }` as a capability
  probe. On native Windows, `symlink` can return false without throwing, causing
  unsupported symlink tests to run. The installer changes only that test's
  probe in an extracted build copy: it creates a real target directory and
  requires a successful symlink and directory check before those tests run.
  The runtime source and assertions for supported platforms are unchanged.
- Module::Pluggable 6.4's install hook failed under native nmake. Version 6.3
  installed successfully with its CPAN tests enabled and is pinned in `cpanfile`.
- The libxml2 static library is built with MSVC/CMake under `.cpanm/native/`
  and installed under `local/native/libxml2/`. The eight native CTest tests stay
  enabled. Iconv and optional programs/Python bindings are unnecessary for this
  application and are disabled; resource encodings are handled by Perl Encode.
- A local `xml2-config.bat` advertises that library to Alien::Libxml2 on native
  Windows, using an absolute `.lib` filename because MSVC's linker does not
  accept Unix `-L` flags. Unix-like systems do not use this helper.
- Installer-only `NO_COLOR`/`ANSI_COLORS_DISABLED` overrides prevent the host
  environment from invalidating YAML::PP's ANSI-color assertions. The original
  tests pass with those environment flags absent.

No CPAN test suite is bypassed or forced. None of these adjustments changes
the converter's lint policies or test expectations.
