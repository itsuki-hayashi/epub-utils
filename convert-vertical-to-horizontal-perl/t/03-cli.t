#!/usr/bin/env perl

use 5.040;
use utf8;

our $VERSION = '0.001';

use Carp qw(croak);

use English    qw(-no_match_vars);
use File::Copy qw(copy);
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
    qw(absolute_path ensure_directory file_exists open_read open_exclusive sha256_file);

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

sub seed_book ( $source, $destination ) {
    my $reader = open_read($source);
    my $writer = open_exclusive($destination);
    copy( $reader, $writer ) or croak "Cannot copy tree fixture: $OS_ERROR";
    close $reader            or croak "Cannot close tree input: $OS_ERROR";
    close $writer            or croak "Cannot close tree fixture: $OS_ERROR";
    return;
}

subtest 'recursive conversion keeps outputs beside each source directory' =>
    sub {
    my $tree  = File::Spec->catdir( $root,  'tree' );
    my $child = File::Spec->catdir( $tree,  'empty-parent', '日本語 [literal]' );
    my $deep  = File::Spec->catdir( $child, 'deeper' );
    ensure_directory($deep);
    ensure_directory( File::Spec->catdir( $tree, 'empty-leaf' ) );
    my $horizontal = File::Spec->catdir( $tree, 'horizontal' );
    ensure_directory($horizontal);
    my $existing = File::Spec->catfile( $horizontal, 'existing.epub' );
    my $reference
        = File::Spec->catfile( $input, 'vertical CSS variants.epub' );
    seed_book( $reference, $existing );
    my @sources = (
        File::Spec->catfile( $tree,  'root.epub' ),
        File::Spec->catfile( $child, 'same.epub' ),
        File::Spec->catfile( $deep,  'same.EPUB' ),
    );
    for my $path (@sources) { seed_book( $reference, $path ); }
    my @hashes       = map { sha256_file($_) } @sources;
    my @destinations = (
        File::Spec->catfile( $horizontal, 'root.epub' ),
        File::Spec->catfile( $child,      'horizontal', 'same.epub' ),
        File::Spec->catfile( $deep,       'horizontal', 'same.EPUB' ),
    );
    my $ignored   = File::Spec->catdir( $root, 'ignored-output' );
    my $report    = File::Spec->catfile( $root, 'recursive-preview.json' );
    my @arguments = (
        '--input-path',       $tree,    '--recursive',
        '--output-directory', $ignored, '--json',
    );
    my $tree_preview
        = run_command( @arguments, '--what-if', '--report-path', $report );
    is $tree_preview->{status}, 0, 'recursive preview succeeds';
    my $records = JSON::PP->new()->utf8()->decode( $tree_preview->{output} );
    is_deeply [ sort map { $_->{Output} } @{$records} ],
        [ sort map { absolute_path($_) } @destinations ],
        'root and nested books each use their own horizontal directory';
    ok !( grep { file_exists($_) } @destinations ),
        'preview creates no books';
    ok !file_exists( File::Spec->catdir( $child, 'horizontal' ) ),
        'preview creates no nested output directory';
    ok !file_exists($report),  'preview creates no report';
    ok !file_exists($ignored), 'ignored output directory is not created';

    my $flat = run_command( '--input-path', $tree, '--output-directory',
        $ignored, '--what-if', '--json' );
    my $flat_records = JSON::PP->new()->utf8()->decode( $flat->{output} );
    is scalar @{$flat_records}, 1, 'default mode remains nonrecursive';
    is $flat_records->[0]{Output},
        absolute_path( File::Spec->catfile( $ignored, 'root.epub' ) ),
        'default mode still honors output-directory';

    my $converted = run_command(@arguments);
    is $converted->{status}, 0, 'recursive conversion succeeds';
    my $converted_records
        = JSON::PP->new()->utf8()->decode( $converted->{output} );
    is_deeply [ map { $_->{Status} } @{$converted_records} ],
        [ map {'Converted'} @sources ],
        'all nested vertical books are converted';
    ok !( grep { !file_exists($_) } @destinations ), 'all output books exist';
    is_deeply [ map { sha256_file($_) } @sources ], \@hashes,
        'all source books remain unchanged';
    is sha256_file($existing), sha256_file($reference),
        'preexisting horizontal directory is excluded and untouched';
    ok !file_exists($ignored), 'conversion ignores output-directory';

    my $tree_analysis = run_command( '--InputPath', $tree, '--Recursive',
        '--AnalyzeOnly', '--json' );
    my $analyzed
        = JSON::PP->new()->utf8()->decode( $tree_analysis->{output} );
    is $tree_analysis->{status}, 0, 'recursive analysis alias succeeds';
    is_deeply [ map { $_->{Status} } @{$analyzed} ],
        [ map {'Analyzed'} @sources ],
        'analysis excludes generated output folders';
    my $repeat = run_command(@arguments);
    is $repeat->{status}, 1, 'repeat conversion refuses existing outputs';
    my $repeated = JSON::PP->new()->utf8()->decode( $repeat->{output} );
    is_deeply [ map { $_->{Status} } @{$repeated} ],
        [ map {'Error'} @sources ],
        'repeat visits sources rather than generated books';
    ok !file_exists( File::Spec->catdir( $horizontal, 'horizontal' ) ),
        'recursive conversion never nests horizontal output directories';
    done_testing();
    return;
    };

done_testing();
