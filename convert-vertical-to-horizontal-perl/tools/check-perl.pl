#!/usr/bin/env perl

use 5.040;

our $VERSION = '0.001';

use Carp       qw(croak);
use Encode     qw(encode);
use English    qw(-no_match_vars);
use File::Find qw(find);
use File::Spec;
use FindBin      qw($RealBin);
use Getopt::Long qw(GetOptions);
use lib "$RealBin/../local/lib/perl5";
use Perl::Critic;
use Perl::Tidy;

my $format = false;
GetOptions( 'format' => \$format )
    or croak 'Usage: perl tools/check-perl.pl [--format]';
my $root = File::Spec->rel2abs( File::Spec->catdir( $RealBin, q{..} ) );
my @files
    = map { File::Spec->catfile( $root, $_ ) } qw(Makefile.PL bin/epub-v2h);
find(
    {   no_chdir => 1,
        wanted   => sub {
            if ( -f $File::Find::name
                && $File::Find::name =~ /[.](?:pl|pm|t)\z/xms )
            {
                push @files, $File::Find::name;
            }
            return;
        }
    },
    map { File::Spec->catdir( $root, $_ ) } qw(lib t tools),
);
my $critic = Perl::Critic->new(
    -profile => File::Spec->catfile( $root, '.perlcriticrc' ) );
my $failures = 0;

sub read_source ($path) {
    open my $handle, '<:raw', $path or croak "Cannot read $path: $OS_ERROR";
    my $source = do { local $INPUT_RECORD_SEPARATOR = undef; <$handle> };
    close $handle or croak "Cannot close $path: $OS_ERROR";
    return $source;
}

sub write_source ( $path, $source ) {
    open my $handle, '>:raw', $path or croak "Cannot update $path: $OS_ERROR";
    print {$handle} $source or croak "Cannot write $path: $OS_ERROR";
    close $handle           or croak "Cannot close $path: $OS_ERROR";
    return;
}

for my $file ( sort @files ) {
    my $source = read_source($file);
    my ( $formatted, $errors );
    my $status = Perl::Tidy::perltidy(
        source      => \$source,
        destination => \$formatted,
        stderr      => \$errors,
        perltidyrc  => File::Spec->catfile( $root, '.perltidyrc' ),

        # The PBP preset selects stdout; this API writes to a memory buffer.
        argv => '--nostandard-output',
    );
    croak "Perl::Tidy failed for $file: $errors" if $status;
    if ( utf8::is_utf8($formatted) ) {
        $formatted = encode( 'UTF-8', $formatted );
    }
    if ( $source ne $formatted ) {
        if ($format) { write_source( $file, $formatted ); }
        else {
            say {*STDERR} "Perl::Tidy mismatch: $file"
                or croak "Cannot print formatting diagnostic: $OS_ERROR";
            $failures++;
        }
    }
    my @violations = $critic->critique($file);
    for my $violation (@violations) {
        say {*STDERR} "$file: $violation"
            or croak "Cannot print critic diagnostic: $OS_ERROR";
        $failures++;
    }
}
croak "$failures formatting/critic checks failed." if $failures;
say scalar(@files)
    . ' owned Perl files pass Perl::Tidy and Perl::Critic (severity 1).'
    or croak "Cannot print check summary: $OS_ERROR";

__END__

=head1 NAME

check-perl.pl - Check or format owned Perl sources without checking dependencies

=head1 SYNOPSIS

    perl tools/check-perl.pl --format
    perl tools/check-perl.pl

=head1 DESCRIPTION

Checks the application, modules, tests and installer. Vendored CPAN bootstrap
code and local dependencies are excluded from this source-file inventory.
Every default severity-1-or-higher Perl::Critic policy remains enabled.

=head1 USAGE

    perl tools/check-perl.pl
    perl tools/check-perl.pl --format

=head1 REQUIRED ARGUMENTS

None. The source root is resolved relative to this script.

=head1 OPTIONS

C<--format> rewrites owned Perl sources using .perltidyrc before checking them.
Without this option, formatting differences are reported without writing files.

=head1 DIAGNOSTICS

Reports formatting mismatches and Perl::Critic violations to standard error.
Malformed options, unreadable files and formatter failures raise exceptions.

=head1 EXIT STATUS

Zero when all files pass. Nonzero if any formatting or critic check fails,
or if a source file cannot be processed.

=head1 CONFIGURATION

Reads .perltidyrc and .perlcriticrc from the distribution root. The profile
selects the requested themes at severity 1. Workspace-local modules are found
under local/lib/perl5 relative to the root.

=head1 DEPENDENCIES

Perl 5.40, Perl::Tidy and Perl::Critic at the versions declared in cpanfile.

=head1 INCOMPATIBILITIES

Formatting results depend on the declared Perl::Tidy version and profile.

=head1 BUGS AND LIMITATIONS

Checks Makefile.PL, bin/epub-v2h and Perl files in lib, t and tools. Vendored
bootstrap code, local dependencies and generated artifacts are excluded.
Static checks do not replace runtime or installation tests.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
