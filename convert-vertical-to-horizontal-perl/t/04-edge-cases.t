#!/usr/bin/env perl

use 5.040;

our $VERSION = '0.001';
use utf8;

use Carp    qw(croak);
use Encode  qw(encode);
use English qw(-no_match_vars);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin    qw($RealBin);
use lib "$RealBin/../local/lib/perl5", "$RealBin/../lib";
use Archive::Zip qw(AZ_OK);
use Test::More;

use Epub::Convert::VerticalToHorizontal qw(process_book);
use Epub::Convert::VerticalToHorizontal::Archive
    qw(open_archive close_archive member_bytes);
use Epub::Convert::VerticalToHorizontal::Files
    qw(ensure_directory file_exists open_exclusive);
use Epub::Convert::VerticalToHorizontal::Text qw(decode_payload parse_xml);

my $fixture = File::Spec->catfile( $RealBin, 'fixtures', 'input',
    'vertical CSS variants.epub' );
my $evidence = File::Spec->catdir( $RealBin, q{..}, 'test-results' );
ensure_directory($evidence);
my $root
    = tempdir( 'perl-edge-cases-XXXXXXXX', DIR => $evidence, CLEANUP => 0 );

sub variant ( $name, $change ) {
    my $archive = open_archive($fixture);
    $change->( $archive->{zip} );
    my $input  = File::Spec->catfile( $root, $name . '.epub' );
    my $handle = open_exclusive($input);
    my $status = $archive->{zip}->writeToFileHandle( $handle, 1 );
    close $handle or croak "Cannot close test variant: $OS_ERROR";
    close_archive($archive);
    croak 'Cannot write test variant.' if $status != AZ_OK;
    return $input;
}

my @failures = (
    [   'duplicate entry',
        sub ($zip) {
            $zip->addString( 'duplicate', 'OPS/image.bin' );
            return;
        },
        qr/Duplicate\s+ZIP\s+entry/xms
    ],
    [   'missing resource',
        sub ($zip) { $zip->removeMember('OPS/styles/main.css'); return; },
        qr/Missing\s+manifest\s+resource/xms
    ],
    [   'malformed XML',
        sub ($zip) {
            $zip->memberNamed('OPS/package.opf')->contents('<package>');
            return;
        },
        qr/parser\s+error/xms
    ],
    [   'signed EPUB',
        sub ($zip) {
            $zip->addString( '<signatures/>', 'META-INF/signatures.xml' );
            return;
        },
        qr/Signed\s+or\s+encrypted/xms
    ],
    [   'encrypted resources',
        sub ($zip) {
            $zip->addString( '<encryption/>', 'META-INF/encryption.xml' );
            return;
        },
        qr/Signed\s+or\s+encrypted/xms
    ],
    [   'missing mimetype',
        sub ($zip) { $zip->removeMember('mimetype'); return; },
        qr/Expected\s+mimetype/xms
    ],
    [   'UTF32 CSS',
        sub ($zip) {
            $zip->memberNamed('OPS/styles/main.css')
                ->contents( pack 'H*', 'fffe0000' );
            return;
        },
        qr/UTF-32/xms
    ],
    [   'external import',
        sub ($zip) {
            my $css = <<'CSS';
@import "https://elsewhere.invalid/style.css"; body {writing-mode:vertical-rl}
CSS
            $zip->memberNamed('OPS/styles/main.css')->contents($css);
            return;
        },
        qr/Unsupported\s+external/xms
    ],
);

for my $case (@failures) {
    my ( $name, $change, $expected_error ) = @{$case};
    subtest $name => sub {
        my $input  = variant( $name, $change );
        my $output = File::Spec->catfile( $root, 'output', $name . '.epub' );
        my $result = process_book( $input, $output );
        is $result->{Status}, 'Error', 'explicit per-book failure';
        like $result->{Error}, $expected_error, 'specific error reason';
        ok !file_exists($output), 'no incomplete output';
        done_testing();
        return;
    };
}

my $mixed_fixed = variant(
    'mixed fixed layout',
    sub ($zip) {
        my $member = $zip->memberNamed('OPS/package.opf');
        my $text   = member_bytes($member);
        $text
            =~ s/<itemref/<itemref properties="rendition:layout-pre-paginated"/xms;
        $member->contents($text);
        return;
    }
);
my $fixed = process_book( $mixed_fixed,
    File::Spec->catfile( $root, 'mixed-fixed-output.epub' ) );
is $fixed->{Reason}, 'FixedLayout', 'mixed fixed-layout books are preserved';
is $fixed->{InputSHA256}, $fixed->{OutputSHA256},
    'mixed fixed-layout archive is an exact copy';

my $utf16 = variant(
    'UTF16 package',
    sub ($zip) {
        my $member = $zip->memberNamed('OPS/package.opf');
        my $text   = member_bytes($member)
            =~ s/encoding="UTF-8"/encoding="UTF-16LE"/rxms;
        $member->contents(
            pack( 'H*', 'fffe' ) . encode( 'UTF-16LE', $text ) );
        return;
    }
);
my $utf16_output = File::Spec->catfile( $root, 'utf16-output.epub' );
my $utf16_result = process_book( $utf16, $utf16_output );
is $utf16_result->{Status}, 'Converted', 'UTF16 package conversion';
my $archive       = open_archive($utf16_output);
my $package_bytes = member_bytes( $archive->{entries}{'OPS/package.opf'} );
close_archive($archive);
is substr( $package_bytes, 0, 2 ), pack( 'H*', 'fffe' ),
    'package BOM preserved';
like decode_payload($package_bytes)->{text},
    qr/page-progression-direction='ltr'/xms,
    'UTF16 metadata converted';

my $entity_rejected = false;
try {
    parse_xml(
        q{<!DOCTYPE root [<!ENTITY example SYSTEM "file:///epub-external-entity-must-not-load">]><root>&example;</root>}
    );
}
catch ($error) { $entity_rejected = true; };
ok $entity_rejected, 'external entity declarations cannot load resources';

my $directory_input = variant(
    'empty directories',
    sub ($zip) {
        $zip->addDirectory('OPS/empty/');
        return;
    }
);
my ( $directory_result, @warnings );
{
    local $SIG{__WARN__}
        = sub ($warning) { push @warnings, $warning; return; };
    $directory_result = process_book( $directory_input,
        File::Spec->catfile( $root, 'directory-output.epub' ) );
}
is $directory_result->{Status}, 'Converted',
    'empty directory entries survive repacking';
is_deeply \@warnings, [], 'empty payloads produce no warnings';

my $unicode_name  = 'OPS/styles/日本語.css';
my $unicode_uri   = '%E6%97%A5%E6%9C%AC%E8%AA%9E.css';
my $unicode_input = variant(
    'Unicode member names',
    sub ($zip) {
        my $bytes = member_bytes( $zip->memberNamed('OPS/styles/main.css') );
        $zip->removeMember('OPS/styles/main.css');
        {
            local $Archive::Zip::UNICODE = 1;
            $zip->addString( $bytes, $unicode_name );
        }
        for my $name ( 'OPS/package.opf', 'OPS/text/page.xhtml' ) {
            my $member = $zip->memberNamed($name);
            my $text   = member_bytes($member);
            $text =~ s/main[.]css/$unicode_uri/gxms;
            $member->contents($text);
        }
        return;
    }
);
my $unicode_result = process_book( $unicode_input,
    File::Spec->catfile( $root, 'unicode-member-output.epub' ) );
is $unicode_result->{Status}, 'Converted',
    'Unicode archive member names resolve';
is_deeply $unicode_result->{ChangedEntries},
    [ 'OPS/package.opf', $unicode_name ],
    'Unicode patch names preserved';

done_testing();
