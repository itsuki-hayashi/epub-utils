#!/usr/bin/env perl

use 5.040;

our $VERSION = '0.001';

use Carp qw(croak);
use utf8;

use Encode  qw(encode);
use FindBin qw($RealBin);
use lib "$RealBin/../local/lib/perl5", "$RealBin/../lib";
use Test::More;

use Epub::Convert::VerticalToHorizontal::Text qw(
    convert_css convert_markup convert_package decode_payload encode_payload
    parse_xml resolve_entry css_imports css_uses_vertical
);

is convert_css('body {writing-mode:vertical-rl}'),
    'body {writing-mode:horizontal-tb}',
    'standard CSS';
is convert_css('body {-epub-writing-mode: vertical-lr !important}'),
    'body {-epub-writing-mode: horizontal-tb !important}',
    'EPUB prefix and importance';
is convert_css('body {-ms-writing-mode:tb-rl}'),
    'body {-ms-writing-mode:lr-tb}',
    'legacy Microsoft mode';
sub COMMENT_REPETITIONS () { return 500; }
my $comments = '/* writing-mode:vertical-rl */ ' x COMMENT_REPETITIONS;
is convert_css( $comments . 'p {writing-mode:vertical-rl}' ),
    $comments . 'p {writing-mode:horizontal-tb}',
    'large comment sequences stay intact';
my $quoted
    = q{body {content:'writing-mode:vertical-rl'; --example: writing-mode:vertical-rl;}};
is convert_css($quoted), $quoted,
    'strings and custom property examples stay intact';
my $page
    = q{<p title=" style='writing-mode:vertical-rl'">writing-mode:vertical-rl;</p>};
is convert_markup($page), $page,
    'prose and quoted unrelated attributes stay intact';
is convert_markup(q{<p style="writing-mode:vertical-rl">日本語</p>}),
    q{<p style="writing-mode:horizontal-tb">日本語</p>}, 'inline style';
is convert_markup(q{<svg:text writing-mode='vertical-lr'>日本語</svg:text>}),
    q{<svg:text writing-mode='horizontal-tb'>日本語</svg:text>}, 'SVG attribute';
is convert_markup(q{<style>body{writing-mode:sideways-rl}</style>}),
    q{<style>body{writing-mode:horizontal-tb}</style>}, 'embedded stylesheet';
my $script = q{<script>var example="writing-mode:vertical-rl";</script>};
is convert_markup($script), $script, 'scripts are not transformed';
is convert_package(
    q{<meta content='vertical-rl' name='primary-writing-mode'/><spine page-progression-direction="rtl">}
    ),
    q{<meta content='horizontal-tb' name='primary-writing-mode'/><spine page-progression-direction="ltr">},
    'package metadata attribute order';
is resolve_entry( 'OPS/package.opf', '../Styles/main%20style.css#fragment' ),
    'Styles/main style.css', 'relative URI resolution';
is resolve_entry(
    'OPS/package.opf', 'text/%E6%97%A5%E6%9C%AC%E8%AA%9E.xhtml'
    ),
    'OPS/text/日本語.xhtml', 'percent-encoded Japanese resource';
is_deeply [
    css_imports(
        q{ /* @import 'unused.css'; */ @import url(extra.css); @import "more.css"; p {content:"@import 'example.css'";}}
    )
    ],
    [ 'extra.css', 'more.css' ], 'CSS import tokens';
ok !css_uses_vertical( '.vrtl {writing-mode:vertical-rl}',
    { hltr => 1 }, {} ),
    'unused toolkit does not trigger conversion';
ok css_uses_vertical( '.vrtl {writing-mode:vertical-rl}', { vrtl => 1 }, {} ),
    'used class triggers conversion';

for my $encoding (qw(UTF-8 UTF-16LE UTF-16BE cp932)) {
    my $text
        = qq{\@charset "$encoding";\r\nbody {writing-mode:vertical-rl} /* 日本語 */};
    my $prefix
        = $encoding eq 'UTF-16LE' ? pack( 'H*', 'fffe' )
        : $encoding eq 'UTF-16BE' ? pack( 'H*', 'feff' )
        :                           q{};
    my $bytes   = $prefix . encode( $encoding, $text );
    my $payload = decode_payload($bytes);
    is encode_payload( $payload, $text ), $bytes,
        "$encoding unchanged round trip";
    my $expected = $text =~ s/vertical-rl/horizontal-tb/rxms;
    is encode_payload( $payload, convert_css( $payload->{text} ) ),
        $prefix . encode( $encoding, $expected ),
        "$encoding edit preserves encoding and CRLF";
}

for my $encoding (qw(UTF-8 UTF-16LE UTF-16BE)) {
    my $text = qq{<?xml version="1.0" encoding="$encoding"?><root>日本語</root>};
    my $document = parse_xml($text);
    is $document->documentElement()->textContent(), '日本語',
        "$encoding XML declaration inspected as decoded text";
}

for my $href ( 'https://elsewhere.invalid/a.css', 'local.css?query' ) {
    my $failed = false;
    try { resolve_entry( 'OPS/package.opf', $href ); }
    catch ($error) { $failed = true; };
    ok $failed, "unsupported resource rejected: $href";
}

done_testing();
