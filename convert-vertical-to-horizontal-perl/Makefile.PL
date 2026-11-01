use 5.040;

use ExtUtils::MakeMaker qw(WriteMakefile);

my %requires = (
    'Archive::Zip' => '1.68',
    'XML::LibXML'  => '2.0207',
    'URI'          => '5.0',
);
if ( $^O eq 'MSWin32' ) {
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

=cut
