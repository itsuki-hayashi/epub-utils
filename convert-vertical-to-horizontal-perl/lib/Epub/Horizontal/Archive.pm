package Epub::Horizontal::Archive;

use 5.044;

use Archive::Zip qw(AZ_OK COMPRESSION_LEVEL_BEST_COMPRESSION COMPRESSION_STORED);
use Carp         qw(croak);
use English      qw(-no_match_vars);
use Digest::SHA  qw(sha256_hex);
use Exporter     qw(import);

use Epub::Horizontal::Files qw(open_read);

our @EXPORT_OK = qw(open_archive close_archive member_bytes repack_archive);

sub open_archive ($path) {
    my $handle = open_read($path);
    my $zip    = Archive::Zip->new();
    if ( $zip->readFromFileHandle($handle) != AZ_OK ) {
        close $handle or croak "Cannot close $path: $OS_ERROR";
        croak "Cannot read EPUB ZIP archive: $path";
    }
    my %entries;
    for my $member ( $zip->members() ) {
        my $name = $member->fileName();
        croak "Duplicate ZIP entry: $name" if exists $entries{$name};
        $entries{$name} = $member;
    }
    return { zip => $zip, handle => $handle, entries => \%entries };
}

sub close_archive ($archive) {
    close $archive->{handle} or croak "Cannot close EPUB archive: $OS_ERROR";
    return;
}

sub member_bytes ($member) {
    croak 'Missing EPUB resource.' if !defined $member;
    my $name = $member->fileName();
    my ( $bytes, $status ) = $member->contents();

    # Reading the local header in Archive::Zip can replace a decoded UTF-8 name
    # with raw filename bytes. Restore the public name before another read or
    # write, otherwise Unicode names can be double-encoded during repacking.
    if ( $member->fileName() ne $name ) {
        $member->fileName($name);
        croak "Unsupported noncanonical ZIP entry name: $name" if $member->fileName() ne $name;
    }
    croak 'Cannot decompress EPUB entry: ' . $member->fileName() if $status != AZ_OK;

    # Archive::Zip represents some empty directory payloads as undef, with an
    # otherwise successful read. Normalize only zero-length payloads to bytes.
    croak 'Missing nonempty EPUB payload: ' . $member->fileName()
        if !defined $bytes && $member->uncompressedSize() != 0;
    return $bytes // q{};
}

sub _verify_mimetype_header ($path) {
    my $handle = open_read($path);
    my $header;
    my $read = read $handle, $header, 30;
    close $handle or croak "Cannot close $path: $OS_ERROR";
    croak 'Incomplete EPUB ZIP header.' if !defined $read || $read != 30;
    my ( $signature, $version, $flags, $method ) = unpack 'Vvvv', $header;
    my $extra_length = unpack 'v', substr $header, 28, 2;
    croak 'Invalid EPUB mimetype ZIP header.'
        if $signature != 0x0403_4b50
        || $flags != 0
        || $method != COMPRESSION_STORED
        || $extra_length != 0;
    return;
}

sub _verify_entries ( $path, $expected ) {
    my $output = open_archive($path);
    try {
        my @members = $output->{zip}->members();
        croak 'Verification failed: entry count changed.' if @members != @{$expected};
        for my $index ( 0 .. $#members ) {
            my $member   = $members[$index];
            my $original = $expected->[$index];
            croak 'Verification failed: ' . $member->fileName()
                if $member->fileName() ne $original->{name}
                || $member->lastModFileDateTime() != $original->{timestamp}
                || $member->externalFileAttributes() != $original->{attributes}
                || sha256_hex( member_bytes($member) ) ne $original->{hash};
        }
    }
    catch ($error) { close_archive($output); croak $error; }
    close_archive($output);
    _verify_mimetype_header($path);
    return;
}

sub repack_archive ( $archive, $patches, $output ) {
    my @members = $archive->{zip}->members();
    croak 'Expected mimetype as the first ZIP entry.'
        if !@members || $members[0]->fileName() ne 'mimetype';
    croak 'Invalid EPUB mimetype payload.' if member_bytes( $members[0] ) ne 'application/epub+zip';
    my @expected;
    for my $member (@members) {
        my $name  = $member->fileName();
        my $bytes = $patches->{$name} // member_bytes($member);
        push @expected,
            {
            name       => $name,
            timestamp  => $member->lastModFileDateTime(),
            attributes => $member->externalFileAttributes(),
            hash       => sha256_hex($bytes),
            };

        # The documented contents setter retains member metadata and makes a
        # StringMember. This forces recompression even for unchanged payloads;
        # setting only the desired level could reuse existing compressed data.
        $member->contents($bytes);

        # The ZipFileMember-to-StringMember transition reads its local header
        # too, so restore a decoded UTF-8 name after the setter as well.
        $member->fileName($name)                               if $member->fileName() ne $name;
        croak "Unsupported noncanonical ZIP entry name: $name" if $member->fileName() ne $name;
        $member->desiredCompressionLevel(
            $name eq 'mimetype' ? 0 : COMPRESSION_LEVEL_BEST_COMPRESSION );
        if ( $name eq 'mimetype' ) {
            $member->localExtraField(q{});
            $member->cdExtraField(q{});
        }
    }
    croak 'Cannot write converted EPUB.'
        if $archive->{zip}->writeToFileHandle( $output->{handle}, 1 ) != AZ_OK;
    close $output->{handle} or croak "Cannot finish converted EPUB: $OS_ERROR";
    $output->{handle} = undef;
    _verify_entries( $output->{path}, \@expected );
    return scalar @expected;
}

1;

__END__

=head1 NAME

Epub::Horizontal::Archive - Maximum-deflate ZIP writing and payload verification

=head1 DESCRIPTION

Rebuilds converted EPUBs at zlib level 9 with mimetype stored first. Every entry
is read back and checked against its expected SHA-256, original name, order,
DOS timestamp and external attributes before publication.

=cut
