package Epub::Convert::VerticalToHorizontal::Files;

use 5.040;

our $VERSION = '0.001';
use utf8;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Config;
use Cwd qw(getcwd);
use Digest::SHA;
use Encode         qw(decode FB_CROAK LEAVE_SRC);
use Exporter       qw(import);
use Fcntl          qw(O_CREAT O_EXCL O_RDWR);
use File::Basename qw(dirname);
use File::Spec;

sub SHA256_BITS () { return 256; }

our @EXPORT_OK = qw(
    absolute_path command_arguments ensure_directory epub_files file_exists
    file_size open_read open_exclusive publish_file remove_file sha256_file
);

if ( $OSNAME eq 'MSWin32' ) {
    require Win32::LongPath;
    require Win32::API;
}

sub _path_text ($path) {
    return $path if utf8::is_utf8($path);
    return decode( 'UTF-8', $path, FB_CROAK | LEAVE_SRC );
}

sub absolute_path ($path) {
    return Win32::LongPath::abspathL($path) if $OSNAME eq 'MSWin32';
    return File::Spec->rel2abs( _path_text($path), _path_text( getcwd() ) );
}

sub file_exists ($path) {
    return Win32::LongPath::testL( 'e', $path ) if $OSNAME eq 'MSWin32';
    return -e $path;
}

sub file_size ($path) {
    if ( $OSNAME eq 'MSWin32' ) {
        my $stat = Win32::LongPath::statL($path)
            or croak "Cannot stat $path: $EXTENDED_OS_ERROR";
        return $stat->{size};
    }
    return -s $path // croak "Cannot stat $path: $OS_ERROR";
}

sub ensure_directory ($path) {
    my $is_directory
        = $OSNAME eq 'MSWin32'
        ? Win32::LongPath::testL( 'd', $path )
        : -d $path;
    return                                            if $is_directory;
    croak "Path exists but is not a directory: $path" if file_exists($path);
    my $parent = dirname($path);
    croak "Cannot create directory: $path" if $parent eq $path;
    ensure_directory($parent);
    my $created
        = $OSNAME eq 'MSWin32' ? Win32::LongPath::mkdirL($path) : mkdir $path;
    croak "Cannot create directory $path: $OS_ERROR $EXTENDED_OS_ERROR"
        if !$created;
    return;
}

sub _is_directory ($path) {
    return Win32::LongPath::testL( 'd', $path ) if $OSNAME eq 'MSWin32';
    return -d $path;
}

sub _is_directory_link ($path) {
    return Win32::LongPath::testL( 'l', $path ) if $OSNAME eq 'MSWin32';
    return -l $path;
}

sub _directory_names ($path) {
    my @names;
    if ( $OSNAME eq 'MSWin32' ) {
        my $directory = Win32::LongPath->new();
        $directory->opendirL($path)
            or croak "Cannot read directory $path: $EXTENDED_OS_ERROR";
        @names = $directory->readdirL();
        $directory->closedirL();
    }
    else {
        opendir my $directory, $path
            or croak "Cannot read directory $path: $OS_ERROR";
        @names = map { _path_text($_) } readdir $directory;
        closedir $directory
            or croak "Cannot close directory $path: $OS_ERROR";
    }
    @names = sort @names;
    return @names;
}

sub _directory_books ( $path, $recursive ) {
    my @queue = ($path);
    my @files;
    while (@queue) {
        my $directory = shift @queue;
        for my $name ( _directory_names($directory) ) {
            next if $name eq q{.} || $name eq q{..};
            my $candidate = File::Spec->catfile( $directory, $name );
            if ( $recursive && _is_directory($candidate) ) {
                if ( lc($name) ne 'horizontal'
                    && !_is_directory_link($candidate) )
                {
                    push @queue, $candidate;
                }
                next;
            }
            next if $name !~ /[.]epub\z/ixms;
            my $is_file
                = $OSNAME eq 'MSWin32'
                ? Win32::LongPath::testL( 'f', $candidate )
                : -f $candidate;
            if ($is_file) { push @files, $candidate; }
        }
    }
    return [ sort @files ];
}

sub epub_files ( $path, $recursive = false ) {
    if ( !_is_directory($path) ) {
        croak 'Input must be an existing EPUB file or directory.'
            if !file_exists($path) || $path !~ /[.]epub\z/ixms;
        return [$path];
    }
    my @files = _directory_books( $path, $recursive )->@*;
    croak 'No EPUB files found.' if !@files;
    return \@files;
}

sub open_read ($path) {
    if ( $OSNAME eq 'MSWin32' ) {
        my $handle;
        Win32::LongPath::openL( \$handle, '<:raw', $path )
            or croak "Cannot open $path: $EXTENDED_OS_ERROR";
        return $handle;
    }
    open my $handle, '<:raw', $path or croak "Cannot open $path: $OS_ERROR";
    return $handle;
}

sub open_exclusive ($path) {
    my $handle;
    my $flags = O_CREAT | O_EXCL | O_RDWR;
    if ( $OSNAME eq 'MSWin32' ) {
        Win32::LongPath::sysopenL( \$handle, $path, $flags )
            or croak "Cannot create $path: $EXTENDED_OS_ERROR";
    }
    else {
        sysopen $handle, $path, $flags
            or croak "Cannot create $path: $OS_ERROR";
    }
    binmode $handle, ':raw' or croak "Cannot set binary mode: $OS_ERROR";
    return $handle;
}

sub publish_file ( $temporary, $destination ) {
    croak "Refusing to overwrite: $destination" if file_exists($destination);
    if ( $OSNAME eq 'MSWin32' ) {

        # MoveFileW, used by renameL, refuses an existing destination atomically.
        Win32::LongPath::renameL( $temporary, $destination )
            or croak "Cannot publish $destination: $EXTENDED_OS_ERROR";
    }
    else {
        # A hard link publishes without the overwrite race of POSIX rename().
        link $temporary, $destination
            or croak "Cannot publish $destination: $OS_ERROR";
        remove_file($temporary);
    }
    return;
}

sub remove_file ($path) {
    return if !file_exists($path);
    my $removed
        = $OSNAME eq 'MSWin32'
        ? Win32::LongPath::unlinkL($path)
        : unlink $path;
    croak "Cannot remove temporary file $path: $OS_ERROR $EXTENDED_OS_ERROR"
        if !$removed;
    return;
}

sub sha256_file ($path) {
    my $handle = open_read($path);
    my $digest = Digest::SHA->new(SHA256_BITS)->addfile($handle)->hexdigest();
    close $handle or croak "Cannot close $path: $OS_ERROR";
    return uc $digest;
}

sub _windows_api ( $library, $name, $input, $output ) {
    return Win32::API::More->new( $library, $name, $input, $output )
        // croak "Cannot load Windows API $name: $EXTENDED_OS_ERROR";
}

sub _wide_string ($pointer) {
    state $length = _windows_api( 'kernel32', 'lstrlenW', 'N', 'I' );
    my $bytes
        = Win32::API::ReadMemory( $pointer, 2 * $length->Call($pointer) );
    return decode( 'UTF-16LE', $bytes, FB_CROAK | LEAVE_SRC );
}

sub command_arguments () {
    if ( $OSNAME ne 'MSWin32' ) {
        return map { _path_text($_) } @ARGV;
    }
    return () if !@ARGV;
    my $command
        = _windows_api( 'kernel32', 'GetCommandLineW', q{}, 'N' )->Call();
    my $count_buffer = pack 'L', 0;
    my $argument_vector
        = _windows_api( 'shell32', 'CommandLineToArgvW', 'NP', 'N' )
        ->Call( $command, $count_buffer );
    croak "Cannot read Unicode command line: $EXTENDED_OS_ERROR"
        if !$argument_vector;
    my $count    = unpack 'L', $count_buffer;
    my @pointers = unpack 'J*',
        Win32::API::ReadMemory( $argument_vector, $count * $Config{ptrsize} );
    my @arguments = map { _wide_string($_) } @pointers;
    _windows_api( 'kernel32', 'LocalFree', 'N', 'N' )->Call($argument_vector);

    # Skip the interpreter, its switches and the script, without assuming how
    # Perl was launched. The final arguments correspond to Perl's original ARGV.
    croak 'Unexpected Windows command-line argument count.'
        if @arguments < @ARGV;
    return @arguments[ @arguments - @ARGV .. $#arguments ];
}

1;

__END__

=head1 NAME

Epub::Convert::VerticalToHorizontal::Files - Literal Unicode paths and verified file operations

=head1 DESCRIPTION

Uses wide Windows APIs for directory names, filenames and command-line
arguments. ZIP libraries receive binary filehandles rather than ANSI paths.
Output creation and publication refuse existing files.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Epub::Convert::VerticalToHorizontal::Files qw(open_read sha256_file);
    my $digest = sha256_file('book.epub');
    my $handle = open_read('book.epub');
    close $handle or die 'Cannot close input';

=head1 SUBROUTINES/METHODS

C<absolute_path($path)> resolves a literal path. C<epub_files($path, $recursive)>
returns an array reference containing a single EPUB path or sorted EPUB paths.
The optional recursive flag defaults to false. Recursive scans include empty
intermediate directories, skip descendant horizontal directories regardless of
case, and do not follow directory links or Windows directory reparse points.
An entirely empty search raises an exception. All paths are collected before
conversion begins, so newly created output directories cannot enter the scan.
C<file_exists($path)> and C<file_size($path)> inspect files.
C<ensure_directory($path)> creates missing parent directories.

C<open_read($path)> opens a binary input handle. C<open_exclusive($path)>
creates a new binary file and rejects existing names. C<publish_file($temp,
$destination)> publishes without replacing an existing file.
C<remove_file($path)> removes a temporary file if present.
C<sha256_file($path)> returns its uppercase SHA-256 hex digest.
C<command_arguments()> returns Unicode command-line arguments.
Private helpers decode paths and call Windows wide APIs. C<SHA256_BITS>
names the digest size.

=head1 DIAGNOSTICS

Throws exceptions for invalid paths, failed file operations, invalid UTF-8,
Windows API failures and attempted overwrites.

=head1 CONFIGURATION AND ENVIRONMENT

Relative paths use the current directory. Windows arguments are recovered
from the process's wide command line; Unix arguments are interpreted as UTF-8.

=head1 DEPENDENCIES

Perl 5.40 and core modules including Digest::SHA and Encode. Windows also
requires Win32::LongPath and Win32::API.

=head1 INCOMPATIBILITIES

Unix publication requires hard-link support within the output filesystem.
Non-UTF-8 Unix filenames and command-line arguments are unsupported.

=head1 BUGS AND LIMITATIONS

The caller must close returned handles. Publication protects destination
names; it does not provide a general filesystem transaction.

=head1 AUTHOR

Itsuki Hayashi.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Itsuki Hayashi.
Distributed under the GNU General Public License version 3. See LICENSE.

=cut
