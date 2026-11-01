package Epub::Convert::VerticalToHorizontal::Text;

use 5.040;

our $VERSION = '0.001';
use utf8;

use Carp       qw(croak);
use Encode     qw(decode encode FB_CROAK LEAVE_SRC);
use Exporter   qw(import);
use English    qw(-no_match_vars);
use List::Util qw(any);
use URI;
use URI::Escape qw(uri_unescape);
use XML::LibXML;

sub UTF16_LE_BOM ()         { return pack 'H*', 'fffe'; }
sub UTF16_BE_BOM ()         { return pack 'H*', 'feff'; }
sub ENCODING_PROBE_BYTES () { return 256; }

our @EXPORT_OK = qw(
    convert_css convert_markup convert_package decode_payload encode_payload
    parse_xml resolve_entry css_imports css_uses_vertical
);

my $css_comment   = qr{ /\* .*? \*/ }xms;
my $css_string    = qr{ " (?: \\. | [^"\\] )* " | ' (?: \\. | [^'\\] )* ' }xms;
my $css_skip      = qr{ $css_comment | $css_string }xms;
my $css_gap       = qr{ (?> (?: \s+ | $css_comment )* ) }xms;
my $vertical_mode = qr{ vertical-rl | vertical-lr | sideways-rl | sideways-lr | tb-rl | tb-lr }ixms;
my $vendor_prefix = qr{ -(?:webkit|epub|ms|moz)- }ixms;
my $css_property  = qr{ (?<property> $vendor_prefix? writing-mode ) }ixms;
my $css_start     = qr{ (?<![^;\{]) $css_gap $css_property }ixms;
my $css_prefix    = qr{ (?<prefix> $css_start $css_gap : $css_gap ) }ixms;
my $css_value_end = qr{ (?= $css_gap (?: ! $css_gap important $css_gap )? (?: [;\}] | \z ) ) }ixms;
my $css_direction = qr{ (?<token>
    $css_prefix (?<value> $vertical_mode ) $css_value_end | $css_skip
) }ixms;
my $xml_encoding = qr{ <\?xml [^>]*? encoding \s*=\s* }ixms;
my $encoding_declaration =
    qr{ \A \s* (?: $xml_encoding | \@charset \s+ ) ["'] (?<encoding> [^"']+ ) }ixms;
my $markup_comment = qr{ <!-- .*? --> }xms;
my $element_prefix = qr{ (?:\w+:)? }xms;
my $script_element =
    qr{ < $element_prefix script \b [^>]* > .*? </ $element_prefix script \s* > }ixms;
my $style_start     = qr{ < $element_prefix style \b [^>]* > }ixms;
my $style_end       = qr{ </ $element_prefix style \s* > }ixms;
my $markup_tag      = qr{ < [A-Za-z] [^>"']* (?: (?: "[^"]*" | '[^']*' ) [^>"']* )* > }xms;
my $attribute_value = qr{ (?<quote> ["'] ) (?<value> .*? ) \k<quote> }xms;
my $attribute_name  = qr{ (?<name> style | writing-mode ) }ixms;
my $style_attribute = qr{ (?<prefix> \s $attribute_name \s*=\s* ) $attribute_value }ixms;
my $attribute_token = qr{ (?<attribute> $style_attribute | " [^"]* " | ' [^']* ' ) }ixms;
my $style_element   = qr{ (?<style> $style_start ) (?<css> .*? ) (?<end> $style_end ) }ixms;
my $markup_token =
    qr{ (?<token> $markup_comment | $script_element | $style_element | (?<tag> $markup_tag ) ) }ixms;
my $quoted_import = qr{ ["'] (?<quoted> [^"']+ ) ["'] }xms;
my $bare_import   = qr{ (?<bare> [^\s)"']+ ) }xms;
my $import_url    = qr{ url\( \s* (?: $quoted_import | $bare_import ) \s* \) }ixms;
my $import_token  = qr{
    $css_skip | \@import \s+ (?: $import_url | ["'] (?<direct> [^"']+ ) ["'] )
}ixms;

sub decode_payload ($bytes) {
    my $encoding = 'UTF-8';
    my $prefix   = q{};
    croak 'UTF-32 resources require manual review.'
        if $bytes =~ /\A (?: \x00\x00\xFE\xFF | \xFF\xFE\x00\x00 )/xms;
    if ( $bytes =~ /\A (\xFF\xFE | \xFE\xFF | \xEF\xBB\xBF)/xms ) {
        $prefix = $1;
        $encoding =
            $prefix eq UTF16_LE_BOM ? 'UTF-16LE' : $prefix eq UTF16_BE_BOM ? 'UTF-16BE' : 'UTF-8';
    }
    elsif ( substr( $bytes, 0, ENCODING_PROBE_BYTES ) =~ $encoding_declaration ) {
        $encoding = $LAST_PAREN_MATCH{encoding};
    }
    my $body = substr $bytes, length $prefix;
    my $text = decode( $encoding, $body, FB_CROAK | LEAVE_SRC );
    croak 'Unsupported text encoding (embedded NUL).' if index( $text, "\0" ) >= 0;
    return { text => $text, encoding => $encoding, prefix => $prefix, bytes => $bytes };
}

sub encode_payload ( $payload, $text ) {
    return $payload->{bytes} if $text eq $payload->{text};
    my $round_trip =
        $payload->{prefix} . encode( $payload->{encoding}, $payload->{text}, FB_CROAK | LEAVE_SRC );
    croak 'Resource encoding does not round-trip exactly.' if $round_trip ne $payload->{bytes};
    return $payload->{prefix} . encode( $payload->{encoding}, $text, FB_CROAK | LEAVE_SRC );
}

sub _xml_parser () {

    # Never consult a local file, a remote DTD, or an external entity. Inspect
    # the DOM only; output always comes from the original resource bytes.
    my $callbacks = XML::LibXML::InputCallback->new();
    $callbacks->register_callbacks(
        [
            sub { return true; },
            sub { croak 'External XML resources are unsupported.'; },
            sub { croak 'External XML resources are unsupported.'; },
            sub { return; },
        ]
    );
    my $parser = XML::LibXML->new(
        no_network      => 1,
        load_ext_dtd    => 0,
        expand_entities => 0,
        recover         => 0,
        ext_ent_handler => sub { croak 'External XML entities are unsupported.'; },
    );
    $parser->input_callbacks($callbacks);
    return $parser;
}

sub parse_xml ($text) {
    state $parser = _xml_parser();

    # The caller has already decoded the resource. Its declaration still names
    # the original byte encoding, which must not be applied to a Unicode string.
    # Normalize only this inspection copy; never serialize it back into the ZIP.
    $text =~ s{ \A ($xml_encoding) (["']) [^"']+ \2 }{${1}${2}UTF-8${2}}xms;
    my $document = $parser->load_xml( string => encode( 'UTF-8', $text, FB_CROAK | LEAVE_SRC ) );
    my $dtd      = $document->internalSubset();
    croak 'XML entity declarations require manual review.'
        if defined $dtd && any { $_->nodeType() == XML::LibXML::XML_ENTITY_DECL() }
        $dtd->childNodes();
    return $document;
}

sub resolve_entry ( $base_path, $href ) {
    my $uri = URI->new_abs( $href, 'https://epub.invalid/' . $base_path );
    croak "Unsupported external/query resource: $href"
        if $uri->scheme ne 'https' || $uri->host ne 'epub.invalid' || defined $uri->query;
    my $path = uri_unescape( $uri->path );
    $path =~ s{\A /}{}xms;
    return decode( 'UTF-8', $path, FB_CROAK | LEAVE_SRC );
}

sub _css_replacement ( $matched, $prefix, $property, $value ) {
    return $matched if !defined $prefix;
    my $horizontal =
        lc($property) eq '-ms-writing-mode' || $value =~ /\A tb-/ixms ? 'lr-tb' : 'horizontal-tb';
    return $prefix . $horizontal;
}

sub convert_css ($text) {
    return $text if $text !~ /writing-mode/ixms;
    $text =~
        s{$css_direction}{ _css_replacement( $LAST_PAREN_MATCH{token}, $LAST_PAREN_MATCH{prefix}, $LAST_PAREN_MATCH{property}, $LAST_PAREN_MATCH{value} ) }egxms;
    return $text;
}

sub _convert_attribute ( $matched, $prefix, $name, $quote, $value ) {
    return $matched if !defined $prefix;
    if    ( lc($name) eq 'style' ) { $value = convert_css($value); }
    elsif ( $value =~ /\A (?: vertical-(?:rl|lr) | sideways-(?:rl|lr) ) \z/ixms ) {
        $value = 'horizontal-tb';
    }
    elsif ( $value =~ /\A tb-(?:rl|lr) \z/ixms ) { $value = 'lr-tb'; }
    return $prefix . $quote . $value . $quote;
}

sub _convert_markup_token ( $matched, $style, $css, $end, $tag ) {
    return $style . convert_css($css) . $end if defined $style;
    return $matched                          if !defined $tag;
    $tag =~ s{$attribute_token}
        { _convert_attribute( $LAST_PAREN_MATCH{attribute}, $LAST_PAREN_MATCH{prefix}, $LAST_PAREN_MATCH{name}, $LAST_PAREN_MATCH{quote}, $LAST_PAREN_MATCH{value} ) }egixms;
    return $tag;
}

sub convert_markup ($text) {
    return $text if $text !~ /writing-mode/ixms;
    $text =~ s{$markup_token}
        { _convert_markup_token( $LAST_PAREN_MATCH{token}, $LAST_PAREN_MATCH{style}, $LAST_PAREN_MATCH{css}, $LAST_PAREN_MATCH{end}, $LAST_PAREN_MATCH{tag} ) }egixms;
    return $text;
}

sub _convert_package_tag ( $tag, $kind ) {
    return $tag if !defined $kind;
    if ( lc($kind) eq 'spine' ) {
        $tag =~ s{ (\s page-progression-direction \s*=\s* ["']) rtl (?=["']) }{${1}ltr}gixms;
    }
    elsif ( $tag =~ /\s name \s*=\s* (["']) primary-writing-mode \1/ixms ) {
        my $content = qr{ (\s content \s*=\s* ["']) }ixms;
        $tag =~ s{ $content (?:vertical|tb) -(?:rl|lr) (?=["']) }{${1}horizontal-tb}gixms;
    }
    return $tag;
}

sub convert_package ($text) {
    my $tag = qr{ < $element_prefix (?<kind> meta | spine ) \b [^>]* > }ixms;
    $text =~ s{ (?<token> $markup_comment | $tag ) }
        { _convert_package_tag( $LAST_PAREN_MATCH{token}, $LAST_PAREN_MATCH{kind} ) }egixms;
    return $text;
}

sub css_imports ($text) {
    $text =~ s{$css_comment}{}gxms;
    my @imports;
    while ( $text =~ /$import_token/gixms ) {
        my $href = $LAST_PAREN_MATCH{quoted} // $LAST_PAREN_MATCH{bare}
            // $LAST_PAREN_MATCH{direct};
        if ( defined $href ) { push @imports, $href; }
    }
    return @imports;
}

sub css_uses_vertical ( $text, $classes, $ids ) {
    $text =~ s{$css_comment}{}gxms;
    while ( $text =~ / (?<selector> [^{}]+ ) \{ (?<body> [^{}]* ) \} /gxms ) {
        my $selector_list = $LAST_PAREN_MATCH{selector};
        my $body          = $LAST_PAREN_MATCH{body};
        next if convert_css($body) eq $body;
        for my $selector ( split /,/xms, $selector_list ) {
            my $used = true;
            while ( $selector =~ / (?<type> [.#] ) (?<name> [\w-]+ ) /gxms ) {
                my $names = $LAST_PAREN_MATCH{type} eq q{.} ? $classes : $ids;
                if ( !exists $names->{ $LAST_PAREN_MATCH{name} } ) { $used = false; }
            }
            return true if $used;
        }
    }
    return false;
}

1;

__END__

=head1 NAME

Epub::Convert::VerticalToHorizontal::Text - Encoding-preserving EPUB direction substitutions

=head1 DESCRIPTION

Small, named transformations preserve comments, CSS strings, markup prose,
original encodings and formatting. XML is inspected without serialization.
Detection intentionally follows the PowerShell converter's declaration-based
heuristics; this module does not implement a complete CSS cascade.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Epub::Convert::VerticalToHorizontal::Text
        qw(decode_payload convert_css encode_payload);
    my $payload = decode_payload($bytes);
    my $output = encode_payload($payload, convert_css($payload->{text}));

=head1 SUBROUTINES/METHODS

C<decode_payload($bytes)> returns decoded C<text>, original C<bytes>,
C<encoding> and BOM C<prefix>. C<encode_payload($payload, $text)> preserves
original bytes when unchanged and checks exact encoding round trips.
C<convert_css($text)>, C<convert_markup($text)> and C<convert_package($text)>
return text with supported vertical declarations changed to horizontal ones.

C<parse_xml($text)> returns a DOM for inspection and refuses external resources
and entity declarations. C<resolve_entry($base, $href)> resolves an internal
EPUB URI to an entry name. C<css_imports($text)> returns imported references.
C<css_uses_vertical($text, \%classes, \%ids)> detects applicable vertical rules.
Private helpers tokenize declarations and markup; uppercase helpers name
byte-order marks and the encoding probe length.

=head1 DIAGNOSTICS

Throws exceptions for unsupported encodings, failed round trips, malformed
XML, entity declarations and external or query-bearing resource references.

=head1 CONFIGURATION AND ENVIRONMENT

No configuration is read. XML parsing disables network access, external DTDs
and external entity loading regardless of document declarations.

=head1 DEPENDENCIES

Perl 5.40, Encode, English, List::Util, URI, URI::Escape and XML::LibXML.

=head1 INCOMPATIBILITIES

UTF-32 and decoded text containing NUL are rejected. Resource encodings must
round-trip exactly when an edit is required.

=head1 BUGS AND LIMITATIONS

The tokenizer does not implement full CSS parsing, selector matching or the
browser cascade. XML is never serialized back into a converted resource.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
