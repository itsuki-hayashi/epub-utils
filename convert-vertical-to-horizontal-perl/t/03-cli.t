#!/usr/bin/env perl

use 5.040;

our $VERSION = '0.001';

use Carp qw(croak);

use English qw(-no_match_vars);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use FindBin    qw($RealBin);
use lib "$RealBin/../local/lib/perl5", "$RealBin/../lib";
use IPC::Open3 qw(open3);
use JSON::PP;
use Test::More;

sub EXIT_STATUS_SHIFT ()    { return 8; }
sub REFERENCE_CASE_COUNT () { return 21; }

use Epub::Convert::VerticalToHorizontal::Files
    qw(ensure_directory file_exists open_read open_exclusive);

my $build  = File::Spec->catdir( $RealBin, q{..}, 'blib' );
my $script = File::Spec->catfile( $RealBin, q{..}, 'bin', 'epub-v2h' );
if ( -d $build ) {
    $script = File::Spec->catfile( $build, 'script', 'epub-v2h' );
}
my $evidence_root = File::Spec->catdir( $RealBin, q{..}, 'test-results' );
ensure_directory($evidence_root);
my $root
    = tempdir( 'perl-cli-XXXXXXXX', DIR => $evidence_root, CLEANUP => 0 );
my $input = File::Spec->catdir( $RealBin, 'fixtures', 'input' );

sub run_command (@arguments) {
    my ( $error, $error_path ) = tempfile( DIR => $root, UNLINK => 1 );
    my $pid = open3(
        my $input_handle,
        my $output_handle,
        '>&' . fileno($error),
        $EXECUTABLE_NAME,
        '-I',
        File::Spec->catdir( $build, 'lib' ),
        '-I',
        File::Spec->catdir( $RealBin, q{..}, 'lib' ),
        '-I',
        File::Spec->catdir( $RealBin, q{..}, 'local', 'lib', 'perl5' ),
        $script,
        @arguments
    );
    close $input_handle or croak "Cannot close child input: $OS_ERROR";
    my $output
        = do { local $INPUT_RECORD_SEPARATOR = undef; <$output_handle> };
    waitpid $pid, 0;
    my $status = $CHILD_ERROR >> EXIT_STATUS_SHIFT;
    seek $error, 0, 0 or croak "Cannot rewind child diagnostics: $OS_ERROR";
    my $diagnostics = do { local $INPUT_RECORD_SEPARATOR = undef; <$error> };
    close $output_handle or croak "Cannot close child output: $OS_ERROR";
    close $error or croak "Cannot close child error output: $OS_ERROR";
    return { status => $status, output => $output, error => $diagnostics };
}

my $help = run_command('--help');
is $help->{status}, 0, 'help succeeds';
like $help->{output}, qr/--analyze-only/xms, 'help documents inspection';
my $preview_directory = File::Spec->catdir( $root, 'preview' );
my $preview_report    = File::Spec->catfile( $root, 'preview.json' );
my $preview
    = run_command( '--input-path', $input, '--output-directory',
    $preview_directory,
    '--report-path', $preview_report, '--what-if', '--json' );
is $preview->{status}, 0, 'CLI dry run succeeds';
ok !file_exists($preview_directory),
    'CLI dry run creates no output directory';
ok !file_exists($preview_report), 'CLI dry run creates no report';
my $preview_results = JSON::PP->new()->utf8()->decode( $preview->{output} );
is scalar @{$preview_results}, REFERENCE_CASE_COUNT,
    'CLI visits all reference cases';
ok !( grep { $_->{Status} ne 'WhatIf' } @{$preview_results} ),
    'dry-run statuses';

my $analysis_report = File::Spec->catfile( $root, 'analysis.json' );
my $analysis
    = run_command( '--InputPath', $input, '--AnalyzeOnly', '--ReportPath',
    $analysis_report, '--json' );
is $analysis->{status}, 0, 'PowerShell-style option aliases';
ok file_exists($analysis_report), 'analysis can write an explicit report';
my $report_handle = open_read($analysis_report);
my $report_text
    = do { local $INPUT_RECORD_SEPARATOR = undef; <$report_handle> };
close $report_handle or croak "Cannot close analysis report: $OS_ERROR";
is_deeply JSON::PP->new()->utf8()->decode($report_text),
    JSON::PP->new()->utf8()->decode( $analysis->{output} ),
    'JSON stdout and report agree';
my $collision = run_command(
    '--input-path', $input, '--analyze-only', '--report-path',
    $analysis_report
);
is $collision->{status}, 1, 'existing report rejected';
like $collision->{error}, qr/Refusing\s+to\s+overwrite\s+report/xms,
    'report error is explicit';

my $mixed = File::Spec->catdir( $root, 'mixed' );
ensure_directory($mixed);
my $invalid
    = open_exclusive( File::Spec->catfile( $mixed, 'a-invalid.epub' ) );
print {$invalid} 'not a ZIP'
    or croak "Cannot write invalid fixture: $OS_ERROR";
close $invalid or croak "Cannot close invalid fixture: $OS_ERROR";
my $valid_source = open_read(
    File::Spec->catfile( $input, 'horizontal English [literal].epub' ) );
my $valid_bytes
    = do { local $INPUT_RECORD_SEPARATOR = undef; <$valid_source> };
close $valid_source or croak "Cannot close valid fixture: $OS_ERROR";
my $valid = open_exclusive( File::Spec->catfile( $mixed, 'z-valid.epub' ) );
print {$valid} $valid_bytes or croak "Cannot write valid fixture: $OS_ERROR";
close $valid                or croak "Cannot close valid fixture: $OS_ERROR";
my $mixed_output = File::Spec->catdir( $root, 'mixed-output' );
my $mixed_result = run_command( '--input-path', $mixed, '--output-directory',
    $mixed_output, '--json' );
is $mixed_result->{status}, 1, 'batch fails if one book fails';
my $mixed_records
    = JSON::PP->new()->utf8()->decode( $mixed_result->{output} );
is_deeply [ map { $_->{Status} } @{$mixed_records} ],
    [ 'Error', 'Preserved' ],
    'later books still complete';
ok file_exists( File::Spec->catfile( $mixed_output, 'z-valid.epub' ) ),
    'valid output published';
ok !file_exists( File::Spec->catfile( $mixed_output, 'a-invalid.epub' ) ),
    'invalid output not published';

done_testing();
