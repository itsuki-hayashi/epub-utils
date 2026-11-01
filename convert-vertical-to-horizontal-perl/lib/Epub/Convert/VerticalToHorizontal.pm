package Epub::Convert::VerticalToHorizontal;

use 5.040;

use Carp           qw(croak);
use English        qw(-no_match_vars);
use Exporter       qw(import);
use File::Basename qw(basename dirname);
use File::Copy     qw(copy);
use File::Spec;

use Epub::Convert::VerticalToHorizontal::Archive
    qw(open_archive close_archive repack_archive);
use Epub::Convert::VerticalToHorizontal::Book  qw(plan_book);
use Epub::Convert::VerticalToHorizontal::Files qw(
    ensure_directory file_exists file_size open_read open_exclusive
    publish_file remove_file sha256_file
);

our $VERSION = '0.001';

our @EXPORT_OK = qw(process_book write_report);
my $temporary_sequence = 0;

sub _temporary_output ($directory) {
    my $path;
    while (true) {
        $path = File::Spec->catfile( $directory,
                  q{.epub-horizontal-}
                . $PID . q{-}
                . ++$temporary_sequence
                . q{.tmp} );
        last if !file_exists($path);
    }
    return { path => $path, handle => open_exclusive($path) };
}

sub _copy_exactly ( $input, $temporary ) {
    my $source = open_read($input);
    my $copied = copy( $source, $temporary->{handle} );
    close $source or croak "Cannot close $input: $OS_ERROR";
    croak "Cannot copy $input: $OS_ERROR" if !$copied;
    close $temporary->{handle} or croak "Cannot finish exact copy: $OS_ERROR";
    $temporary->{handle} = undef;
    return;
}

sub _publish_book ( $input, $archive, $plan, $result ) {
    my $directory = dirname( $result->{Output} );
    ensure_directory($directory);
    my $temporary = _temporary_output($directory);
    try {
        $result->{InputSHA256} = sha256_file($input);
        if ( $plan->{kind} eq 'Preserved' ) {
            _copy_exactly( $input, $temporary );
            croak 'Exact-copy verification failed.'
                if sha256_file( $temporary->{path} ) ne
                $result->{InputSHA256};
        }
        else { repack_archive( $archive, $plan->{patches}, $temporary ); }
        $result->{OutputSHA256} = sha256_file( $temporary->{path} );
        $result->{OutputBytes}  = file_size( $temporary->{path} );
        publish_file( $temporary->{path}, $result->{Output} );
    }
    catch ($error) {
        if ( defined $temporary->{handle} ) {
            close $temporary->{handle}
                or croak "Cannot close temporary output: $OS_ERROR";
        }
        remove_file( $temporary->{path} );
        croak $error;
    };
    return;
}

sub process_book ( $input, $destination, $options = {} ) {
    my $result = {
        Book            => basename($input),
        Status          => q{},
        Reason          => q{},
        ChangedEntries  => [],
        EntriesVerified => 0,
        InputBytes      => 0,
        OutputBytes     => undef,
        InputSHA256     => q{},
        OutputSHA256    => q{},
        Output          => $destination,
        Error           => q{},
    };
    my $archive;
    try {
        $result->{InputBytes} = file_size($input);
        $archive = open_archive($input);
        my $plan = plan_book($archive);
        $result->{Reason}         = $plan->{reason};
        $result->{ChangedEntries} = [ sort keys $plan->{patches}->%* ];
        if ( $options->{analyze_only} ) { $result->{Status} = 'Analyzed'; }
        else {
            croak "Refusing to overwrite: $destination"
                if file_exists($destination);
            if ( $options->{what_if} ) { $result->{Status} = 'WhatIf'; }
            else {
                _publish_book( $input, $archive, $plan, $result );
                $result->{Status} = $plan->{kind};
                $result->{EntriesVerified}
                    = scalar $archive->{zip}->members();
            }
        }
    }
    catch ($error) {
        $result->{Status} = 'Error';
        $result->{Error}  = "$error";
    };
    if ( defined $archive ) { close_archive($archive); }
    return $result;
}

sub write_report ( $path, $json ) {
    croak "Refusing to overwrite report: $path" if file_exists($path);
    my $temporary = _temporary_output( dirname($path) );
    try {
        print { $temporary->{handle} } $json
            or croak "Cannot write report: $OS_ERROR";
        close $temporary->{handle} or croak "Cannot finish report: $OS_ERROR";
        $temporary->{handle} = undef;
        publish_file( $temporary->{path}, $path );
    }
    catch ($error) {
        if ( defined $temporary->{handle} ) {
            close $temporary->{handle}
                or croak "Cannot close report: $OS_ERROR";
        }
        remove_file( $temporary->{path} );
        croak $error;
    };
    return;
}

1;

__END__

=head1 NAME

Epub::Convert::VerticalToHorizontal - Inspect, convert, verify and safely publish one EPUB

=head1 DESCRIPTION

C<process_book($input, $destination, \%options)> returns the same per-book
report fields as the PowerShell converter. Options C<analyze_only> and
C<what_if> prevent output creation. Failures become C<Error> records so a
batch can continue; partially written temporary files are removed.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Epub::Convert::VerticalToHorizontal qw(process_book write_report);
    my $result = process_book('vertical.epub', 'horizontal/book.epub');
    die $result->{Error} if $result->{Status} eq 'Error';

=head1 SUBROUTINES/METHODS

C<process_book($input, $destination, \%options)> returns status, reason,
changed entry names, verification count, sizes and hashes for one EPUB.
C<analyze_only> suppresses book output; C<what_if> previews publication.
Existing destination files are rejected. Operational failures are returned in
C<Error> with C<Status> set to C<Error>.

C<write_report($path, $json)> publishes already serialized JSON to a new file.
It refuses existing reports and requires an existing parent directory.
Private helpers manage temporary files, verified copying and publication.

=head1 DIAGNOSTICS

Book failures appear in returned records. Report failures throw exceptions.
Messages identify missing resources, invalid archives and overwrite attempts.

=head1 CONFIGURATION AND ENVIRONMENT

No configuration files are read. Paths and options are supplied by the caller.

=head1 DEPENDENCIES

Perl 5.40, this distribution's Archive, Book and Files modules, and their
prerequisites. See Makefile.PL or cpanfile for supported versions.

=head1 INCOMPATIBILITIES

Signed or encrypted vertical books and unsupported encodings cannot be edited.

=head1 BUGS AND LIMITATIONS

Conversion changes direction declarations, not rendered page layout.
See README.md for preservation guarantees and classification limitations.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
