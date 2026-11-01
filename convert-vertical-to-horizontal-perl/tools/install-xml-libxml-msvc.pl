#!/usr/bin/env perl

use 5.040;

our $VERSION = '0.001';

use Carp qw(croak);
use Config;
use Cwd qw(getcwd);
use Digest::SHA;
use English    qw(-no_match_vars);
use File::Path qw(make_path);
use File::Spec;
use File::Temp   qw(tempdir tempfile);
use FindBin      qw($RealBin);
use Getopt::Long qw(GetOptions);

sub usage () {
    return <<'USAGE';
Usage: perl tools/install-xml-libxml-msvc.pl [options]

Run in a matching Visual Studio Developer PowerShell or command prompt.
By default, installs CPAN modules into the running Perl's site directories.

  --native-prefix DIR  Native library directory (default: Perl siteprefix/native/libxml2/2.15.4)
  --local-lib DIR      Install CPAN modules into this isolated directory instead
  --check              Check platform, tools and source checksums without installing
  --help               Show this help

Builds and tests static libxml2 2.15.4, patches only PkgConfig's symlink test,
installs Module::Pluggable 6.3, and reinstalls Alien::Libxml2 0.20 and
XML::LibXML 2.0213. No dependency test suites are bypassed or forced.
USAGE
}

sub command (@arguments) {
    say '+ ' . join q{ }, @arguments
        or croak "Cannot print command: $OS_ERROR";
    my $status = system { $arguments[0] } @arguments;
    croak "Cannot start $arguments[0]: $OS_ERROR"            if $status < 0;
    croak "Command failed (wait status $status): @arguments" if $status;
    return;
}

sub perl_program ( $source, $switches, $arguments ) {

    # A script file avoids Windows command-line quoting ambiguities with -e.
    my ( $handle, $path ) = tempfile( SUFFIX => '.pl', UNLINK => 1 );
    print {$handle} $source or croak "Cannot write Perl probe: $OS_ERROR";
    close $handle           or croak "Cannot close Perl probe: $OS_ERROR";
    command( $EXECUTABLE_NAME, @{$switches}, $path, @{$arguments} );
    return;
}

sub checked_source ( $root, $name, $expected ) {
    my $path = File::Spec->catfile( $root, split m{/}xms, $name );
    open my $handle, '<:raw', $path or croak "Cannot read $path: $OS_ERROR";
    my $digest = Digest::SHA->new('SHA-256')->addfile($handle)->hexdigest();
    close $handle or croak "Cannot close $path: $OS_ERROR";
    croak "Source checksum mismatch: $path" if $digest ne $expected;
    return $path =~ s{\\}{/}grxms;
}

sub sources ($root) {
    my %files;
    my %hashes = (
        'tools/cpanm' =>
            '137e8c5856e09867f6d7631d6d67a5e7778166962e29830c573cbbbab6ed2e21',
        'vendor/libxml2-2.15.4.tar.xz' =>
            '98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821',
        'vendor/PkgConfig-0.26026.tar.gz' =>
            '5352ed156a4b5de8c523771ee399f6f8ce5e8bfcf8674f1e1dbd4a8c83643b85',
        'vendor/Module-Pluggable-6.3.tar.gz' =>
            '58512bb9c654746d0937770b98b559b30872d85ac24073485e5830890dd1b2a0',
    );
    for my $name ( sort keys %hashes ) {
        $files{$name} = checked_source( $root, $name, $hashes{$name} );
    }
    return \%files;
}

sub native_prefix ($requested) {
    my $prefix = $requested;
    if ( !defined $prefix ) {
        my $base = $Config{siteprefix};
        croak 'Perl siteprefix is unset; specify --native-prefix.'
            if !defined $base || !length $base;
        $prefix = File::Spec->catdir( $base, 'native', 'libxml2', '2.15.4' );
    }
    $prefix = File::Spec->rel2abs($prefix);
    $prefix =~ s{\\}{/}gxms;

    # These characters cannot safely round-trip through a cmd.exe batch file.
    croak 'Use an ASCII native prefix without quotes, %, ! or line breaks.'
        if $prefix =~ / [^[:ascii:]] | ["%!\r\n] /xms;
    return $prefix;
}

sub preflight () {
    croak 'This installer requires native Windows Perl built with MSVC.'
        if $OSNAME ne 'MSWin32'
        || ( $Config{ccname} // q{} ) !~ /\A cl (?:[.]exe)? \z/ixms
        || $Config{make} !~ /(?:\A|[\\\/]) nmake (?:[.]exe)? \z/ixms;
    for my $tool (qw(cl.exe nmake.exe cmake.exe ctest.exe tar.exe)) {
        command( 'where.exe', $tool );
    }
    my $probe = <<'PROBE';
die "No working MSVC toolchain\n" unless ExtUtils::CBuilder->new->have_compiler;
PROBE
    my $previous = getcwd();
    my $scratch  = tempdir( CLEANUP => 1 );
    chdir $scratch
        or croak "Cannot enter compiler probe directory: $OS_ERROR";
    try { perl_program( $probe, ['-MExtUtils::CBuilder'], [] ); }
    catch ($error) {
        chdir $previous
            or croak "Cannot restore working directory: $OS_ERROR";
        croak $error;
    }
    chdir $previous or croak "Cannot restore working directory: $OS_ERROR";
    return;
}

sub build_native ( $archive, $work, $prefix ) {
    command( 'tar', '-xf', $archive, '-C', $work );
    my $build = File::Spec->catdir( $work, 'libxml2-build' );
    command(
        'cmake',
        '-S',
        File::Spec->catdir( $work, 'libxml2-2.15.4' ),
        '-B',
        $build,
        '-G',
        'NMake Makefiles',
        '-DCMAKE_BUILD_TYPE=Release',
        "-DCMAKE_INSTALL_PREFIX=$prefix",
        '-DBUILD_SHARED_LIBS=OFF',
        '-DLIBXML2_WITH_ICONV=OFF',
        '-DLIBXML2_WITH_PROGRAMS=OFF',
        '-DLIBXML2_WITH_PYTHON=OFF',
        '-DLIBXML2_WITH_TESTS=ON',
    );
    command( 'cmake', '--build',    $build );
    command( 'ctest', '--test-dir', $build, '--output-on-failure' );
    command( 'cmake', '--install',  $build );
    for my $file ( 'include/libxml2/libxml/parser.h', 'lib/libxml2s.lib' ) {
        croak "Native installation is incomplete: $prefix/$file"
            if !-f "$prefix/$file";
    }
    my $bin = File::Spec->catdir( $prefix, 'bin' );
    make_path($bin);
    my $config = <<"BATCH";
\@echo off
if "%~1"=="--version" echo 2.15.4
if "%~1"=="--cflags" echo -I"$prefix/include/libxml2" -DLIBXML_STATIC
if "%~1"=="--libs" echo "$prefix/lib/libxml2s.lib" bcrypt.lib
BATCH
    $config =~ s/\r?\n/\r\n/gxms;
    my $path = File::Spec->catfile( $bin, 'xml2-config.bat' );
    open my $handle, '>:raw', $path or croak "Cannot create $path: $OS_ERROR";
    print {$handle} $config or croak "Cannot write $path: $OS_ERROR";
    close $handle           or croak "Cannot close $path: $OS_ERROR";
    return $bin;
}

sub patch_pkg_config ( $archive, $work ) {
    command( 'tar', '-xf', $archive, '-C', $work );
    my $package = File::Spec->catdir( $work, 'PkgConfig-0.26026' );
    my $test = File::Spec->catfile( $package, 't', '01-script_detailed.t' );
    open my $input, '<:raw', $test or croak "Cannot read $test: $OS_ERROR";
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$input> };
    close $input or croak "Cannot close $test: $OS_ERROR";
    my $old         = 'if (eval { symlink("",""); 1 }) {';
    my $replacement = <<'PROBE';
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
    open my $output, '>:raw', $test or croak "Cannot update $test: $OS_ERROR";
    print {$output} $text or croak "Cannot write $test: $OS_ERROR";
    close $output         or croak "Cannot close $test: $OS_ERROR";
    return $package =~ s{\\}{/}grxms;
}

sub verify_installation ( $prefix, $local_lib ) {
    my @include;
    if ( defined $local_lib ) {
        push @include, '-I', File::Spec->catdir( $local_lib, 'lib', 'perl5' );
    }
    my $verify = <<'VERIFY';
use Alien::Libxml2;
use XML::LibXML;
my $prefix = shift @ARGV;
die "Alien did not select the supplied library\n"
    unless Alien::Libxml2->install_type eq 'system'
    && index(Alien::Libxml2->libs, "$prefix/lib/libxml2s.lib") >= 0;
my $doc = XML::LibXML->load_xml(string => '<root>ok</root>');
die "XML parsing failed\n" unless $doc->documentElement->textContent eq 'ok';
print "XML::LibXML $XML::LibXML::VERSION\n",
      "Loaded from $INC{'XML/LibXML.pm'}\n",
      'libxml2 runtime ', XML::LibXML::LIBXML_RUNTIME_VERSION(), "\n",
      'Alien flags: ', Alien::Libxml2->libs, "\n"
    or die "Cannot print verification: $!\n";
VERIFY
    perl_program( $verify, \@include, [$prefix] );
    return;
}

sub main () {
    my ( $requested_prefix, $local_lib, $check, $help );
    Getopt::Long::Configure(qw(no_auto_abbrev no_ignore_case));
    GetOptions(
        'native-prefix=s' => \$requested_prefix,
        'local-lib=s'     => \$local_lib,
        'check'           => \$check,
        'help|h'          => \$help,
    ) or croak usage();
    croak usage() if @ARGV;
    if ($help) {
        print usage() or croak "Cannot print help: $OS_ERROR";
        return;
    }

    # All child Perl processes start without inherited workspace installations.
    local %ENV = %ENV;
    delete @ENV{
        qw(PERL5LIB PERL5OPT PERL_LOCAL_LIB_ROOT PERL_MB_OPT PERL_MM_OPT PERL_CPANM_OPT
            ALIEN_INSTALL_TYPE NO_COLOR ANSI_COLORS_DISABLED)
    };
    local @ENV{qw(LC_ALL LC_CTYPE LANG)} = qw(C C C);
    preflight();
    my $prefix = native_prefix($requested_prefix);
    my $root   = File::Spec->rel2abs( File::Spec->catdir( $RealBin, q{..} ) );
    my $files  = sources($root);
    if ($check) {
        say "Preflight passed. Native prefix: $prefix"
            or croak "Cannot print preflight result: $OS_ERROR";
        return;
    }
    my $cache = File::Spec->catdir( $root, '.cpanm', 'msvc-xml' );
    make_path($cache);
    my $work = tempdir( 'run-XXXXXXXX', DIR => $cache, CLEANUP => 0 );
    local $ENV{PERL_CPANM_HOME} = File::Spec->catdir( $work, 'cpanm' );
    say "Build sources and logs: $work"
        or croak "Cannot print path: $OS_ERROR";
    local $ENV{PATH} = build_native( $files->{'vendor/libxml2-2.15.4.tar.xz'},
        $work, $prefix )
        . $Config{path_sep}
        . $ENV{PATH};
    local $ENV{ALIEN_INSTALL_TYPE} = 'system';
    my @install = (
        $EXECUTABLE_NAME, $files->{'tools/cpanm'},
        '--mirror', 'https://cpan.metacpan.org', '--mirror-only',
    );

    if ( defined $local_lib ) {
        $local_lib = File::Spec->rel2abs($local_lib);
        push @install, '--local-lib-contained', $local_lib;
    }
    my $pkg = patch_pkg_config( $files->{'vendor/PkgConfig-0.26026.tar.gz'},
        $work );

    # cpanminus recognizes directory targets only when they start with ./ or /.
    # A Windows drive-qualified path is otherwise interpreted as a module name.
    my $previous = getcwd();
    chdir $pkg or croak "Cannot enter PkgConfig build: $OS_ERROR";
    command( @install, '--reinstall', q{.} );
    chdir $previous or croak "Cannot restore working directory: $OS_ERROR";
    command( @install, $files->{'vendor/Module-Pluggable-6.3.tar.gz'} );
    command( @install, '--reinstall', 'Alien::Libxml2@0.20' );
    command( @install, '--reinstall', 'XML::LibXML@2.0213' );
    verify_installation( $prefix, $local_lib );
    return;
}

main();

__END__

=head1 NAME

install-xml-libxml-msvc.pl - Install XML::LibXML into MSVC-built Windows Perl

=head1 DESCRIPTION

Builds static libxml2, supplies a Windows xml2-config wrapper, patches only
PkgConfig's symlink capability test and installs the tested CPAN versions.
Alien::Libxml2 is reinstalled to refresh saved absolute compiler/linker paths.
The XML::LibXML runtime source is unchanged. Every dependency runs its normal
test suite; no force or no-test options are used.

=head1 USAGE

    perl tools/install-xml-libxml-msvc.pl --check
    perl tools/install-xml-libxml-msvc.pl
    perl tools/install-xml-libxml-msvc.pl --local-lib C:/PerlModules/xml

=head1 REQUIRED ARGUMENTS

None. Run from a matching Visual Studio Developer PowerShell or command prompt.

=head1 OPTIONS

C<--native-prefix DIR> selects the persistent native library directory. The
default is C<$Config{siteprefix}/native/libxml2/2.15.4>, derived from the
interpreter running this script. For the user-local Perl installation this is
C<%LOCALAPPDATA%/Programs/Perl/site/native/libxml2/2.15.4>. The prefix contains
C<bin>, C<include> and C<lib> directories alongside installed site modules.
Separate Perl installations already isolate their architectures, so no extra
architecture directory is added.
Keep it in place for future XS builds. It must be an ASCII path without double
quotes, percent signs, exclamation marks or line breaks.

C<--local-lib DIR> installs CPAN modules into a contained local tree instead
of the running Perl's site directories. Set PERL5LIB to its lib/perl5 directory
to use that installation afterwards. This does not relocate the native library.

C<--check> validates the compiler, tools and vendored source checksums without
installing or creating build directories. It performs a temporary compiler probe.
C<--help> prints usage without checking the platform or installing anything.

=head1 DIAGNOSTICS

Every child command is checked and failures stop installation immediately.
Build directories and CPAN logs remain under .cpanm/msvc-xml/run-* for diagnosis.
Verification loads the installed modules in a fresh Perl subprocess and checks
Alien's native library path and basic XML parsing.

=head1 EXIT STATUS

Zero on success or help; nonzero for invalid options, unsupported Perl,
unavailable tools, checksum mismatches, build/test errors or verification failure.

=head1 CONFIGURATION

Uses the interpreter that launches this script. Child processes do not inherit
PERL5LIB, PERL5OPT, local::lib paths, PERL_CPANM_OPT, or MakeMaker/Module::Build
install overrides. Inherited cpanminus options cannot disable dependency tests
or redirect the selected installation.
Locale and color overrides affect only this process and its children.
System installation requires write access to this Perl's site directories.
No permanent environment changes are made. Fresh build directories prevent
reuse of relocated CMake caches. Native sources and cpanminus are checksum checked.

=head1 DEPENDENCIES

MSVC-built Windows Perl 5.40 or later, its core modules, a matching MSVC/SDK
developer environment, nmake, CMake, CTest, Windows tar, the bundled tools/cpanm
and vendor archives, and HTTPS access to CPAN. Installs Module::Pluggable 6.3,
Alien::Libxml2 0.20 and XML::LibXML 2.0213 alongside their dependencies.

=head1 INCOMPATIBILITIES

Strawberry/MinGW Perl, Unix Perl and mismatched compiler architectures are not
supported. Do not share XS module installations between different Perl builds.

=head1 BUGS AND LIMITATIONS

Iconv, optional libxml2 programs and Python bindings are disabled, matching the
converter's tested native configuration. This script installs XML dependencies,
not the EPUB converter. Interrupted installation can leave partially installed
files; rerun to rebuild and retest. Site installation replaces the selected
CPAN packages, including the Module::Pluggable 6.3 workaround.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
