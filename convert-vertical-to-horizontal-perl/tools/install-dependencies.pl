#!/usr/bin/env perl

use 5.040;

our $VERSION = '0.001';

use Archive::Tar;
use Config;
use Carp        qw(croak);
use Cwd         qw(getcwd);
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use File::Path  qw(make_path);
use File::Spec;
use FindBin qw($RealBin);
use Module::Metadata;

my $root = File::Spec->rel2abs( File::Spec->catdir( $RealBin, q{..} ) );
$root =~ s{\\}{/}gxms;
my $local   = File::Spec->catdir( $root, 'local' );
my $cpanm   = File::Spec->catfile( $RealBin, 'cpanm' );
my @install = (
    $EXECUTABLE_NAME, $cpanm, '--local-lib-contained', $local,
    '--mirror',       'https://cpan.metacpan.org', '--mirror-only'
);

# These overrides apply only to the installer and its children. ANSI color
# tests must not inherit the host's NO_COLOR policy. Keep all build caches and
# installed modules in this workspace; no sudo, force installs or skipped tests.
local %ENV = %ENV;
delete @ENV{qw(NO_COLOR ANSI_COLORS_DISABLED)};
local $ENV{LC_ALL}          = 'C';
local $ENV{LC_CTYPE}        = 'C';
local $ENV{LANG}            = 'C';
local $ENV{PERL_CPANM_HOME} = File::Spec->catdir( $root, '.cpanm' );

sub install (@arguments) {
    system { $install[0] } @install, @arguments;
    croak "Dependency installation failed (status $CHILD_ERROR)."
        if $CHILD_ERROR;
    return;
}

sub command (@arguments) {
    system { $arguments[0] } @arguments;
    croak "Command failed (status $CHILD_ERROR): @arguments" if $CHILD_ERROR;
    return;
}

sub checked_archive ( $name, $expected_hash ) {
    my $path = File::Spec->catfile( $root, 'vendor', $name );
    open my $handle, '<:raw', $path
        or croak "Cannot read vendored archive: $OS_ERROR";
    my $bytes = do { local $INPUT_RECORD_SEPARATOR = undef; <$handle> };
    close $handle or croak "Cannot close vendored archive: $OS_ERROR";
    croak "Vendored archive checksum mismatch: $name"
        if sha256_hex($bytes) ne $expected_hash;
    return $path;
}

sub installed_version ($name) {
    my $info = Module::Metadata->new_from_module( $name,
        inc => [ File::Spec->catdir( $local, 'lib', 'perl5' ) ] );
    return $info ? $info->version() : q{};
}

sub native_xml () {
    my $prefix  = File::Spec->catdir( $local,  'native', 'libxml2' );
    my $native  = File::Spec->catdir( $root,   '.cpanm', 'native' );
    my $build   = File::Spec->catdir( $native, 'libxml2-build' );
    my $library = File::Spec->catfile( $prefix, 'lib', 'libxml2s.lib' );
    if ( !-f $library ) {
        my $source = checked_archive( 'libxml2-2.15.4.tar.xz',
            '98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821'
        );
        make_path($native);
        command( 'tar', '-xf', $source, '-C', $native );
        command(
            'cmake',
            '-S',
            File::Spec->catdir( $native, 'libxml2-2.15.4' ),
            '-B',
            $build,
            '-G',
            'NMake Makefiles',
            '-DCMAKE_BUILD_TYPE=Release',
            "-DCMAKE_INSTALL_PREFIX=$prefix",
            '-DBUILD_SHARED_LIBS=OFF',
            '-DLIBXML2_WITH_ICONV=OFF',
            '-DLIBXML2_WITH_PROGRAMS=OFF',
            '-DLIBXML2_WITH_PYTHON=OFF'
        );
        command( 'cmake', '--build',    $build );
        command( 'ctest', '--test-dir', $build, '--output-on-failure' );
        command( 'cmake', '--install',  $build );
    }
    $prefix =~ s{\\}{/}gxms;
    my $bin    = File::Spec->catdir( $prefix, 'bin' );
    my $config = File::Spec->catfile( $bin, 'xml2-config.bat' );

    # Alien::Libxml2's Unix shell config cannot execute on native Windows.
    # Use absolute .lib paths because MSVC's linker does not accept -L flags.
    open my $handle, '>:raw', $config
        or croak "Cannot create native XML config: $OS_ERROR";
    print {$handle} join "\r\n", '@echo off',
        'if "%~1"=="--version" echo 2.15.4',
        qq{if "%~1"=="--cflags" echo -I"$prefix/include/libxml2" -DLIBXML_STATIC},
        qq{if "%~1"=="--libs" echo "$prefix/lib/libxml2s.lib" bcrypt.lib}, q{}
        or croak "Cannot write native XML config: $OS_ERROR";
    close $handle or croak "Cannot close native XML config: $OS_ERROR";
    return $bin;
}

sub patched_pkg_config () {
    my $source = checked_archive( 'PkgConfig-0.26026.tar.gz',
        '5352ed156a4b5de8c523771ee399f6f8ce5e8bfcf8674f1e1dbd4a8c83643b85' );
    my $build = File::Spec->catdir( $root, '.cpanm', 'bootstrap' );
    make_path($build);
    my $old_directory = getcwd();
    chdir $build
        or croak "Cannot enter dependency build directory: $OS_ERROR";
    Archive::Tar->extract_archive( $source, 1 )
        or croak 'Cannot unpack PkgConfig.';
    chdir $old_directory
        or croak "Cannot restore working directory: $OS_ERROR";
    my $package = File::Spec->catdir( $build, 'PkgConfig-0.26026' );
    my $test = File::Spec->catfile( $package, 't', '01-script_detailed.t' );
    open my $input, '<:raw', $test
        or croak "Cannot read PkgConfig test: $OS_ERROR";
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$input> };
    close $input or croak "Cannot close PkgConfig test: $OS_ERROR";
    my $old         = 'if (eval { symlink("",""); 1 }) {';
    my $replacement = <<'PROBE';
# Local portability fix: a false symlink() result does not throw, so an eval
# ending in 1 is not a capability check. Probe an existing directory instead.
require File::Temp;
require File::Spec;
my $probe_root = File::Temp::tempdir(CLEANUP => 1);
my $probe_target = File::Spec->catdir($probe_root, 'target');
mkdir $probe_target or die "Cannot create symlink probe: $!";
my $probe_link = File::Spec->catdir($probe_root, 'link');
my $can_symlink = symlink($probe_target, $probe_link) && -d $probe_link;
if ($can_symlink) {
PROBE
    croak 'PkgConfig patch context changed.' if index( $text, $old ) < 0;
    $text =~ s{\Q$old\E}{$replacement}xms;
    open my $output, '>:raw', $test
        or croak "Cannot patch PkgConfig test: $OS_ERROR";
    print {$output} $text or croak "Cannot write PkgConfig patch: $OS_ERROR";
    close $output         or croak "Cannot close PkgConfig patch: $OS_ERROR";
    return $package =~ s{\\}{/}grxms;
}

if ( $OSNAME eq 'MSWin32' && !installed_version('PkgConfig') ) {
    chdir patched_pkg_config()
        or croak "Cannot enter PkgConfig source: $OS_ERROR";
    install(q{.});
}
chdir $root or croak "Cannot enter workspace: $OS_ERROR";
if ( installed_version('Module::Pluggable') ne '6.3' ) {
    checked_archive( 'Module-Pluggable-6.3.tar.gz',
        '58512bb9c654746d0937770b98b559b30872d85ac24073485e5830890dd1b2a0' );
    install(q{./vendor/Module-Pluggable-6.3.tar.gz});
}
local $ENV{PATH}
    = $OSNAME eq 'MSWin32'
    ? native_xml() . $Config{path_sep} . $ENV{PATH}
    : $ENV{PATH};
local $ENV{ALIEN_INSTALL_TYPE}
    = $OSNAME eq 'MSWin32' ? 'system' : $ENV{ALIEN_INSTALL_TYPE};
install( '--installdeps', q{.}, '--with-develop' );

__END__

=head1 NAME

install-dependencies.pl - Install cpanfile dependencies into workspace-local local/

=head1 DESCRIPTION

Uses the vendored cpanminus bootstrap. CPAN tests remain enabled. Native Windows
uses an otherwise unmodified PkgConfig distribution with an accurate symlink
capability probe in its tests. No runtime PkgConfig code is patched.

=head1 USAGE

    perl tools/install-dependencies.pl

=head1 REQUIRED ARGUMENTS

None. The workspace root is resolved relative to this script.

=head1 OPTIONS

No command-line options are supported. Dependencies are selected by cpanfile.

=head1 DIAGNOSTICS

Prints CPAN and native build progress. Raises exceptions for failed commands,
checksum mismatches, unsupported patch contexts or failed file operations.

=head1 EXIT STATUS

Zero after successful installation; nonzero for any failed prerequisite,
command or verification step. Dependency test suites are not skipped.

=head1 CONFIGURATION

Installs into local/ and keeps caches under .cpanm/. Uses the HTTPS MetaCPAN
mirror. It sets child locale variables to C, removes inherited color disabling
variables for dependency tests, and selects native Windows libxml2 when needed.
On Windows, a matching MSVC developer environment, CMake, nmake and tar must
be available on PATH. Unix-like systems use XML::LibXML's normal build path.

=head1 DEPENDENCIES

Perl 5.40, the vendored cpanminus bootstrap and checked vendored native sources.
Internet access and platform build tools may be needed for CPAN prerequisites.

=head1 INCOMPATIBILITIES

Native Windows builds require tools matching the Perl installation. A local
installation cannot be shared between Windows and Linux Perl interpreters.

=head1 BUGS AND LIMITATIONS

The installer provisions dependencies, not the application itself. Use
Makefile.PL and make install to install the executable. Vendored portability
patches depend on exact upstream source versions and are checksum checked.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
