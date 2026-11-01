package Epub::Convert::VerticalToHorizontal::Book;

use 5.040;

our $VERSION = '0.001';

use Carp     qw(croak);
use Exporter qw(import);

use Epub::Convert::VerticalToHorizontal::Archive qw(member_bytes);
use Epub::Convert::VerticalToHorizontal::Text    qw(
    convert_css convert_markup convert_package decode_payload encode_payload
    parse_xml resolve_entry css_imports css_uses_vertical
);

our @EXPORT_OK = qw(plan_book);

sub MINIMUM_IMAGE_PAGES () { return 10; }
sub IMAGE_PAGE_FRACTION () { return 0.8; }

my %markup_media
    = map { $_ => true } qw(application/xhtml+xml image/svg+xml text/html);
my $visible_text = <<'XPATH';
    (//*[local-name()="body"]//text() | /*[local-name()="svg"]//text())
    [normalize-space(.) != "" and not(ancestor::*[
        local-name()="script" or local-name()="style" or
        local-name()="title" or local-name()="desc"
    ])][1]
XPATH

sub _payload ( $archive, $path ) {
    croak "Missing EPUB resource: $path"
        if !exists $archive->{entries}{$path};
    return decode_payload( member_bytes( $archive->{entries}{$path} ) );
}

sub _package ($archive) {
    my $container
        = parse_xml( _payload( $archive, 'META-INF/container.xml' )->{text} );
    my @roots = $container->findnodes('//*[local-name()="rootfile"]');
    croak 'Multiple or missing package rootfiles require manual review.'
        if @roots != 1;
    my $path = resolve_entry( 'container.xml',
        $roots[0]->getAttribute('full-path') );
    my $payload  = _payload( $archive, $path );
    my $document = parse_xml( $payload->{text} );
    return { path => $path, payload => $payload, document => $document };
}

sub _fixed_layout ($document) {
    for my $meta ( $document->findnodes('//*[local-name()="meta"]') ) {
        my $text = $meta->textContent();
        $text =~ s{\A \s+ | \s+ \z}{}gxms;
        return true
            if ( $meta->getAttribute('property') // q{} ) eq
            'rendition:layout'
            && $text eq 'pre-paginated';
        return true
            if ( $meta->getAttribute('name') // q{} ) eq 'fixed-layout'
            && ( $meta->getAttribute('content') // q{} ) eq 'true';
    }
    for my $reference ( $document->findnodes('//*[local-name()="itemref"]') )
    {
        return true
            if ( $reference->getAttribute('properties') // q{} )
            =~ /(?:\A|\s) rendition:layout-pre-paginated (?:\s|\z)/xms;
    }
    return false;
}

sub _primary_vertical ($document) {
    for my $meta ( $document->findnodes('//*[local-name()="meta"]') ) {
        return true
            if ( $meta->getAttribute('name') // q{} ) eq
            'primary-writing-mode'
            && ( $meta->getAttribute('content') // q{} )
            =~ /\A (?:vertical|tb) -(?:rl|lr) \z/ixms;
    }
    return false;
}

sub _manifest ( $archive, $package ) {
    my ( %items, %resources );
    for my $item ( $package->{document}
        ->findnodes('//*[local-name()="manifest"]/*[local-name()="item"]') )
    {
        my $path = resolve_entry( $package->{path},
            ( $item->getAttribute('href') // q{} ) );
        croak "Missing manifest resource: $path"
            if !exists $archive->{entries}{$path};
        my $id = ( $item->getAttribute('id') // q{} );
        croak "Duplicate manifest id: $id" if exists $items{$id};
        my $media = ( $item->getAttribute('media-type') // q{} );
        $items{$id}       = { path => $path, media => $media };
        $resources{$path} = $media;
    }
    return { items => \%items, resources => \%resources };
}

sub _inspect_spine ( $archive, $package, $manifest ) {
    my @spine = $package->{document}
        ->findnodes('//*[local-name()="spine"]/*[local-name()="itemref"]');
    croak 'Empty or missing spine.' if !@spine;
    my $scan = {
        documents       => {},
        classes         => {},
        ids             => {},
        linked_css      => {},
        inline_vertical => false,
        image_pages     => 0,
        text_pages      => 0,
    };
    for my $reference (@spine) {
        my $id = ( $reference->getAttribute('idref') // q{} );
        croak "Unknown spine idref: $id" if !exists $manifest->{items}{$id};
        my $resource = $manifest->{items}{$id};
        next if !exists $markup_media{ $resource->{media} };
        my $path = $resource->{path};
        next if exists $scan->{documents}{$path};
        my $payload  = _payload( $archive, $path );
        my $document = parse_xml( $payload->{text} );
        $scan->{documents}{$path} = $payload;

        for my $node ( $document->findnodes('//*[@class]') ) {
            for my $class ( grep {length} split /\s+/xms,
                ( $node->getAttribute('class') // q{} ) )
            {
                $scan->{classes}{$class} = true;
            }
        }
        for my $node ( $document->findnodes('//*[@id]') ) {
            $scan->{ids}{ ( $node->getAttribute('id') // q{} ) } = true;
        }
        for my $link (
            $document->findnodes('//*[local-name()="link"][@href]') )
        {
            next
                if ( $link->getAttribute('rel') // q{} )
                !~ /(?:\A|\s) stylesheet (?:\s|\z)/ixms;
            $scan->{linked_css}{
                resolve_entry(
                    $path, ( $link->getAttribute('href') // q{} )
                )
            } = true;
        }
        if ( $document->findnodes($visible_text)->size() ) {
            $scan->{text_pages}++;
        }
        elsif (
            $document->findnodes(
                '//*[local-name()="img" or local-name()="image"]')->size()
            )
        {
            $scan->{image_pages}++;
        }
        $scan->{inline_vertical}
            ||= convert_markup( $payload->{text} ) ne $payload->{text};
    }
    return $scan;
}

sub _inspect_styles ( $archive, $scan ) {
    my @queue = sort keys $scan->{linked_css}->%*;
    my %payloads;
    my $active_vertical = false;
    while (@queue) {
        my $path = shift @queue;
        next if exists $payloads{$path};
        my $payload = _payload( $archive, $path );
        $payloads{$path} = $payload;
        push @queue,
            map { resolve_entry( $path, $_ ) }
            css_imports( $payload->{text} );
        $active_vertical
            ||= css_uses_vertical( $payload->{text}, $scan->{classes},
            $scan->{ids} );
    }
    return { payloads => \%payloads, active_vertical => $active_vertical };
}

sub _patch_resources ( $archive, $manifest, $scan, $styles ) {
    my %patches;
    my %resources = (
        ( map { $_ => 'text/css' } keys $styles->{payloads}->%* ),
        $manifest->{resources}->%*
    );
    for my $path ( sort keys %resources ) {
        my $media = $resources{$path};
        next if $media ne 'text/css' && !exists $markup_media{$media};
        my $payload = $styles->{payloads}{$path} // $scan->{documents}{$path}
            // _payload( $archive, $path );
        my $text
            = $media eq 'text/css'
            ? convert_css( $payload->{text} )
            : convert_markup( $payload->{text} );
        if ( $text ne $payload->{text} ) {
            $patches{$path} = encode_payload( $payload, $text );
        }
    }
    return \%patches;
}

sub plan_book ($archive) {
    my $package = _package($archive);
    my $plan
        = { kind => 'Preserved', reason => 'FixedLayout', patches => {} };
    return $plan if _fixed_layout( $package->{document} );
    my $manifest = _manifest( $archive, $package );
    my $scan     = _inspect_spine( $archive, $package, $manifest );
    if ( !$scan->{text_pages} ) {
        $plan->{reason} = 'ImageOnly';
        return $plan;
    }
    if (   $scan->{image_pages} >= MINIMUM_IMAGE_PAGES
        && $scan->{image_pages}
        / ( $scan->{image_pages} + $scan->{text_pages} )
        >= IMAGE_PAGE_FRACTION )
    {
        $plan->{reason} = 'ImageDominated';
        return $plan;
    }
    my $styles = _inspect_styles( $archive, $scan );
    if (   !_primary_vertical( $package->{document} )
        && !$scan->{inline_vertical}
        && !$styles->{active_vertical} )
    {
        $plan->{reason} = 'Horizontal';
        return $plan;
    }
    croak
        'Signed or encrypted EPUB requires manual review before modifying resources.'
        if exists $archive->{entries}{'META-INF/signatures.xml'}
        || exists $archive->{entries}{'META-INF/encryption.xml'};
    my $patches = _patch_resources( $archive, $manifest, $scan, $styles );
    my $package_text = convert_package( $package->{payload}{text} );
    if ( $package_text ne $package->{payload}{text} ) {
        $patches->{ $package->{path} }
            = encode_payload( $package->{payload}, $package_text );
    }
    croak
        'Vertical evidence found but no supported direction setting could be changed.'
        if !keys %{$patches};
    return {
        kind    => 'Converted',
        reason  => 'VerticalText',
        patches => $patches
    };
}

1;

__END__

=head1 NAME

Epub::Convert::VerticalToHorizontal::Book - Inspect EPUB layouts and plan minimal resource changes

=head1 DESCRIPTION

Discovers the package, manifest, spine and imported stylesheets. Preserves
horizontal, fixed-layout, image-only and image-dominated books. Plans direction
substitutions for vertical reflowable books without extracting or rewriting XML.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Epub::Convert::VerticalToHorizontal::Book qw(plan_book);
    my $plan = plan_book($archive);
    # $archive comes from Archive::open_archive().

=head1 SUBROUTINES/METHODS

C<plan_book($archive)> returns C<kind>, C<reason> and a C<patches> hash mapping
entry names to replacement bytes. Preserved books have no patches. The archive
remains open and its payloads are inspected without extraction.
Private helpers resolve resources, classify spine content and inspect styles.
C<MINIMUM_IMAGE_PAGES> and C<IMAGE_PAGE_FRACTION> name the image dominance
thresholds used to preserve illustrated books.

=head1 DIAGNOSTICS

Throws exceptions for missing or duplicate resources, invalid XML, unsupported
external references, empty spines and signed or encrypted conversion targets.

=head1 CONFIGURATION AND ENVIRONMENT

Classification rules are fixed. No environment variables are read directly.

=head1 DEPENDENCIES

Perl 5.40 and this distribution's Archive and Text modules.

=head1 INCOMPATIBILITIES

Multiple package rootfiles and incomplete or malformed EPUBs are unsupported.

=head1 BUGS AND LIMITATIONS

Class and ID detection is a declaration heuristic, not a browser CSS cascade.
The image dominance heuristic may preserve heavily illustrated text books.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
