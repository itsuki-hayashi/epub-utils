use 5.040;

our $VERSION = '0.001';

use ExtUtils::MakeMaker qw(WriteMakefile);
use English             qw(-no_match_vars);

my %requires = (
    'Archive::Zip' => '1.68',
    'XML::LibXML'  => '2.0207',
    'URI'          => '5.0',
);
if ( $OSNAME eq 'MSWin32' ) {
    $requires{'Win32::LongPath'} = '2.3';
    $requires{'Win32::API'}      = '0.84';
}

my %modules;
for my $source ( glob('lib/Epub/Convert/*.pm'), glob('lib/Epub/Convert/VerticalToHorizontal/*.pm') )
{
    my $target = $source;
    $target =~ s{\Alib/}{\$(INST_LIB)/}xms;
    $modules{$source} = $target;
}
WriteMakefile(
    PM                 => \%modules,
    NAME               => 'Epub::Convert::VerticalToHorizontal',
    VERSION_FROM       => 'lib/Epub/Convert/VerticalToHorizontal.pm',
    ABSTRACT           => 'Preserve horizontal EPUBs and convert vertical text',
    AUTHOR             => 'Itsuki Hayashi',
    LICENSE            => 'gpl_3',
    MIN_PERL_VERSION   => '5.040000',
    CONFIGURE_REQUIRES => { 'ExtUtils::MakeMaker' => '7.70' },
    TEST_REQUIRES      => { 'Test::More'          => '1.302199' },
    PREREQ_PM          => \%requires,
    EXE_FILES          => ['bin/epub-v2h'],
    META_MERGE         => {
        'meta-spec'    => { version => 2 },
        dynamic_config => 1,
        no_index       => { directory => [qw(t tools vendor)] },
        resources      => {
            repository => {
                type => 'git',
                url  => 'https://github.com/itsuki-hayashi/epub-utils.git',
                web  => 'https://github.com/itsuki-hayashi/epub-utils',
            },
            bugtracker => { web => 'https://github.com/itsuki-hayashi/epub-utils/issues' },
        },
    },
);

__END__

=head1 NAME

Makefile.PL - Configure the Epub::Convert::VerticalToHorizontal distribution

=head1 DESCRIPTION

Uses ExtUtils::MakeMaker to install modules and the command-line executable.
On Windows, MakeMaker wraps the installed executable using pl2bat.

=head1 USAGE

    perl Makefile.PL
    make
    make test
    make install

Use the make utility configured for Perl, such as nmake for native MSVC Perl.

=head1 REQUIRED ARGUMENTS

None. Run from the distribution root.

=head1 OPTIONS

Accepts standard ExtUtils::MakeMaker options. C<INSTALL_BASE=/prefix> selects
an installation prefix; default installation uses Perl's site directories.

=head1 DIAGNOSTICS

MakeMaker reports missing prerequisites and build configuration errors.
It declares prerequisites but does not install them automatically.

=head1 EXIT STATUS

Zero when a Makefile is generated successfully; nonzero for configuration errors.

=head1 CONFIGURATION

Uses the running Perl's Config settings and platform-specific prerequisites.
C<PERL5LIB> can select locally installed dependencies. See ExtUtils::MakeMaker
for build environment variables and installation path options.

=head1 DEPENDENCIES

Perl 5.40 and ExtUtils::MakeMaker 7.70 or newer. Runtime and test prerequisites
are declared in this file and in cpanfile.

=head1 INCOMPATIBILITIES

Use a make utility compatible with the running Perl. Generated Makefiles must
be regenerated when moving between Windows and Unix-like systems.

=head1 BUGS AND LIMITATIONS

Native prerequisites, including XML::LibXML, may need build tools or system
libraries. MakeMaker does not provision those external tools.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
