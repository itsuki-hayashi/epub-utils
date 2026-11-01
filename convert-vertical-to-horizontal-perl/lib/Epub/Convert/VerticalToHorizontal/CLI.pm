package Epub::Convert::VerticalToHorizontal::CLI;

use 5.040;

our $VERSION = '0.001';

use Carp           qw(croak);
use English        qw(-no_match_vars);
use Exporter       qw(import);
use File::Basename qw(basename dirname);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;

use Epub::Convert::VerticalToHorizontal qw(process_book write_report);
use Epub::Convert::VerticalToHorizontal::Files
    qw(absolute_path epub_files file_exists);

our @EXPORT_OK = qw(run_cli);

sub _usage () {
    return <<'USAGE';
Usage: epub-v2h [options]

  --input-path PATH        EPUB file or directory (default: working directory)
  --output-directory DIR   Output directory (default: BASE/horizontal)
  --analyze-only           Inspect without creating output EPUBs
  --what-if                Preview without writing books or a report
  --report-path FILE       Write JSON verification report; never overwrite
  --json                   Print the result array as JSON instead of a table
  --verbose                Print each input path to standard error
  --help                   Show this help

Horizontal, fixed-layout and image-based books are exact copies.
Converted text books use DEFLATE level 9, with mimetype stored first.
Existing files are never replaced. A failed book does not stop later books.
USAGE
}

sub _options ($arguments) {
    my %options;
    Getopt::Long::Configure(qw(no_auto_abbrev no_ignore_case));
    my $parsed = GetOptionsFromArray(
        $arguments,
        'input-path|InputPath=s'             => \$options{input},
        'output-directory|OutputDirectory=s' => \$options{output},
        'analyze-only|AnalyzeOnly'           => \$options{analyze_only},
        'what-if|WhatIf'                     => \$options{what_if},
        'report-path|ReportPath=s'           => \$options{report},
        'json'                               => \$options{json},
        'verbose|Verbose'                    => \$options{verbose},
        'help|h'                             => \$options{help},
    );
    croak _usage() if !$parsed || @{$arguments};
    return \%options;
}

sub _paths ( $options, $script_directory ) {
    my $input  = absolute_path( $options->{input} // $script_directory );
    my $output = absolute_path( $options->{output}
            // File::Spec->catdir( $script_directory, 'horizontal' ) );
    my $report
        = defined $options->{report}
        ? absolute_path( $options->{report} )
        : undef;
    croak "Refusing to overwrite report: $report"
        if defined $report && file_exists($report) && !$options->{what_if};
    croak 'Report directory must already exist.'
        if defined $report && !file_exists( dirname($report) );
    return { input => $input, output => $output, report => $report };
}

sub _show_result ( $result, $options ) {
    if ( $result->{Status} eq 'Error' ) {
        print {*STDERR} "$result->{Book}: $result->{Error}"
            or croak "Cannot print error: $OS_ERROR";
    }
    if ( !$options->{json} ) {
        say join "\t", $result->@{qw(Status Reason Book)}
            or croak "Cannot print result: $OS_ERROR";
    }
    return;
}

sub _run_batch ( $options, $paths ) {
    my @results;

    for my $book ( epub_files( $paths->{input} )->@* ) {
        if ( $options->{verbose} ) { say {*STDERR} "Inspecting $book"; }
        my $destination
            = File::Spec->catfile( $paths->{output}, basename($book) );
        my $result = process_book( $book, $destination, $options );
        push @results, $result;
        _show_result( $result, $options );
    }
    return \@results;
}

sub run_cli ( $arguments, $script_directory ) {
    my $options = _options($arguments);
    if ( $options->{help} ) {
        print _usage() or croak "Cannot print help: $OS_ERROR";
        return 0;
    }
    my $paths   = _paths( $options, $script_directory );
    my $results = _run_batch( $options, $paths );
    my $json    = JSON::PP->new()->canonical()->pretty();
    if ( defined $paths->{report} && !$options->{what_if} ) {
        write_report( $paths->{report}, $json->utf8()->encode($results) );
    }
    if ( $options->{json} ) {
        print $json->utf8(0)->encode($results)
            or croak "Cannot print JSON: $OS_ERROR";
    }
    my $failures = grep { $_->{Status} eq 'Error' } @{$results};
    if ($failures) {
        say {*STDERR}
            "$failures EPUB(s) failed; other books were processed independently.";
    }
    return $failures ? 1 : 0;
}

1;

__END__

=head1 NAME

Epub::Convert::VerticalToHorizontal::CLI - Cross-platform command-line interface and JSON reports

=head1 DESCRIPTION

Provides inspection, dry runs, batch conversion, independent per-book errors
and reports compatible with Test-EpubCollection.ps1.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Epub::Convert::VerticalToHorizontal::CLI qw(run_cli);
    my @arguments = ('--input-path', 'book.epub', '--analyze-only');
    my $status = run_cli(\@arguments, $base_directory);

=head1 SUBROUTINES/METHODS

C<run_cli(\@arguments, $base_directory)> consumes options, processes a file
or nonrecursive directory and returns zero on success or one on book failure.
The supplied base directory determines default input and output paths.
Private helpers parse options, resolve paths, run batches and print records.

=head1 DIAGNOSTICS

Book diagnostics go to standard error while later books continue. Invalid
options, invalid paths and report failures throw exceptions for the executable
to catch. Use C<--json> for machine-readable standard output.

=head1 CONFIGURATION AND ENVIRONMENT

Options include C<--input-path>, C<--output-directory>, C<--report-path>,
C<--analyze-only>, C<--what-if>, C<--json>, C<--verbose> and C<--help>.
No configuration file is read.

=head1 DEPENDENCIES

Perl 5.40, Getopt::Long, JSON::PP, the main converter and Files modules.

=head1 INCOMPATIBILITIES

Existing output books and reports are never replaced. Directory scans are
nonrecursive and filenames are literal rather than shell patterns.

=head1 BUGS AND LIMITATIONS

A conversion report establishes byte preservation and supported direction
changes; it cannot establish visual appearance in a particular reader.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
