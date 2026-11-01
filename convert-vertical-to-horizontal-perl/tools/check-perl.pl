#!/usr/bin/env perl

use 5.044;

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
GetOptions( 'format' => \$format ) or croak 'Usage: perl tools/check-perl.pl [--format]';
my $root  = File::Spec->rel2abs( File::Spec->catdir( $RealBin, '..' ) );
my @files = ( File::Spec->catfile( $root, 'Convert-EpubToHorizontal.pl' ) );
find(
    {
        no_chdir => 1,
        wanted   => sub {
            push @files, $File::Find::name
                if -f $File::Find::name && $File::Find::name =~ /[.](?:pl|pm|t)\z/xms;
            return;
        }
    },
    map { File::Spec->catdir( $root, $_ ) } qw(lib t tools),
);
my $critic   = Perl::Critic->new( -profile => File::Spec->catfile( $root, '.perlcriticrc' ) );
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
        argv        => q{},
    );
    croak "Perl::Tidy failed for $file: $errors" if $status;
    $formatted = encode( 'UTF-8', $formatted )   if utf8::is_utf8($formatted);
    if ( $source ne $formatted ) {
        if ($format) { write_source( $file, $formatted ); }
        else         { say {*STDERR} "Perl::Tidy mismatch: $file"; $failures++; }
    }
    my @violations = $critic->critique($file);
    for my $violation (@violations) {
        say {*STDERR} "$file: $violation";
        $failures++;
    }
}
croak "$failures formatting/critic checks failed." if $failures;
say scalar(@files) . ' owned Perl files pass Perl::Tidy and Perl::Critic (severity 3).';

__END__

=head1 NAME

check-perl.pl - Check or format owned Perl sources without checking dependencies

=head1 SYNOPSIS

    perl tools/check-perl.pl --format
    perl tools/check-perl.pl

=head1 DESCRIPTION

Checks the application, modules, tests and installer. Vendored CPAN bootstrap
code and local dependencies are excluded from this source-file inventory.
Every default severity-3-or-higher Perl::Critic policy remains enabled.

=cut
