#!/usr/bin/env perl

use 5.044;

use Carp qw(croak);
use utf8;

use English    qw(-no_match_vars);
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin    qw($RealBin);
use lib "$RealBin/../local/lib/perl5", "$RealBin/../lib";
use JSON::PP;
use Test::More;

use Epub::Horizontal          qw(process_book);
use Epub::Horizontal::Archive qw(open_archive close_archive member_bytes);
use Epub::Horizontal::Files   qw(
    absolute_path ensure_directory file_exists open_read open_exclusive sha256_file
);

my $fixture_root    = File::Spec->catdir( $RealBin, 'fixtures' );
my $manifest_handle = open_read( File::Spec->catfile( $fixture_root, 'manifest.json' ) );
my $manifest_text   = do { local $INPUT_RECORD_SEPARATOR = undef; <$manifest_handle> };
close $manifest_handle or croak "Cannot close fixture manifest: $OS_ERROR";
my $cases         = JSON::PP->new()->utf8()->decode($manifest_text);
my $evidence_root = File::Spec->catdir( $RealBin, '..', 'test-results' );
ensure_directory($evidence_root);
my $output_root = tempdir( 'perl-fixtures-XXXXXXXX', DIR => $evidence_root, CLEANUP => 0 );
my $second_root = File::Spec->catdir( $output_root, 'second' );

sub compare_entries ( $actual_path, $expected_path ) {
    my $actual           = open_archive($actual_path);
    my $expected         = open_archive($expected_path);
    my @actual_members   = $actual->{zip}->members();
    my @expected_members = $expected->{zip}->members();
    is scalar @actual_members, scalar @expected_members, 'entry count';
    for my $index ( 0 .. $#expected_members ) {
        my $a = $actual_members[$index];
        my $e = $expected_members[$index];
        is $a->fileName(),               $e->fileName(),               'entry name and order';
        is $a->lastModFileDateTime(),    $e->lastModFileDateTime(),    'DOS timestamp';
        is $a->externalFileAttributes(), $e->externalFileAttributes(), 'external attributes';
        is member_bytes($a), member_bytes($e), 'exact expected payload: ' . $a->fileName();
    }
    close_archive($actual);
    close_archive($expected);
    return;
}

for my $case ( @{$cases} ) {
    subtest $case->{Book} => sub {
        my $input         = File::Spec->catfile( $fixture_root, 'input',    $case->{Book} );
        my $expected      = File::Spec->catfile( $fixture_root, 'expected', $case->{Book} );
        my $output        = File::Spec->catfile( $output_root,  $case->{Book} );
        my $original_hash = sha256_file($input);
        my $result        = process_book( $input, $output );
        is $result->{Status}, $case->{Reason} eq 'VerticalText' ? 'Converted' : 'Preserved',
            'conversion status';
        is $result->{Reason}, $case->{Reason}, 'PowerShell classification parity';
        is_deeply $result->{ChangedEntries}, $case->{ChangedEntries}, 'minimal patch list parity';
        is sha256_file($input), $original_hash, 'source untouched';

        if ( $result->{Status} ne 'Error' ) {
            compare_entries( $output, $expected );
            my $repeat =
                process_book( $output, File::Spec->catfile( $second_root, $case->{Book} ) );
            is $repeat->{Status}, 'Preserved', 'second pass preserves';
            is $repeat->{InputSHA256}, $repeat->{OutputSHA256},
                'second pass is an exact archive copy';
            is $result->{InputSHA256}, $result->{OutputSHA256},
                'unchanged books are exact file copies'
                if $case->{Reason} ne 'VerticalText';
        }
        else { diag $result->{Error}; }
        done_testing();
    };
}

# Exercise actual Unicode filenames, nested output directories, and long paths.
my $unicode_root = File::Spec->catdir(
    $output_root,
    '日本語 📚 [literal]',
    map { 'directory-' . $_ . '-' . ( '長' x 25 ) } 1 .. 5
);
ensure_directory($unicode_root);
my $unicode_input = File::Spec->catfile( $unicode_root, '縦書きの本.epub' );
my $source =
    open_read( File::Spec->catfile( $fixture_root, 'input', 'vertical CSS variants.epub' ) );
my $destination = open_exclusive($unicode_input);
copy( $source, $destination ) or croak "Cannot copy Unicode fixture: $OS_ERROR";
close $source                 or croak "Cannot close Unicode fixture source: $OS_ERROR";
close $destination            or croak "Cannot close Unicode fixture: $OS_ERROR";
my $unicode_output = File::Spec->catfile( $unicode_root, '出力', '横書きの本.epub' );
my $unicode_result = process_book( $unicode_input, $unicode_output );
is $unicode_result->{Status}, 'Converted', 'Unicode filesystem input/output';
diag $unicode_result->{Error} if $unicode_result->{Status} eq 'Error';

my $preview_directory = File::Spec->catdir( $output_root, 'preview' );
my $preview           = process_book(
    $unicode_input,
    File::Spec->catfile( $preview_directory, 'book.epub' ),
    { what_if => 1 }
);
is $preview->{Status}, 'WhatIf', 'dry run';
ok !file_exists($preview_directory), 'dry run creates no directory';
my $analysis = process_book( $unicode_input, $unicode_output, { analyze_only => 1 } );
is $analysis->{Status}, 'Analyzed', 'analysis works even when output already exists';
my $overwrite = process_book( $unicode_input, $unicode_output );
is $overwrite->{Status}, 'Error', 'overwrite rejected';
like $overwrite->{Error}, qr/Refusing\s+to\s+overwrite/xms, 'overwrite error is explicit';

diag 'Evidence directory: ' . absolute_path($output_root);
done_testing();
