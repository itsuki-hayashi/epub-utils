use 5.040;
use strict;
use warnings;
use File::Spec;
use FindBin qw($RealBin);
use lib "$RealBin/../../convert-vertical-to-horizontal-perl/lib";
use Epub::Convert::VerticalToHorizontal::Archive
    qw(open_archive close_archive member_bytes);

my $conversion = @ARGV && $ARGV[0] eq 'conversion';
my $input = File::Spec->catdir($RealBin, '..', '..',
    'convert-vertical-to-horizontal-perl', 't', 'fixtures',
    $conversion ? 'expected' : 'input');
my $output = File::Spec->catdir($RealBin, '..', 'test-results',
    $conversion ? 'book-parity' : 'archive-roundtrip');
$output = $ARGV[1] if @ARGV > 1;
opendir my $directory, $input or die "Cannot enumerate fixtures: $!";
my @names = sort grep { /[.]epub\z/ } readdir $directory;
closedir $directory or die "Cannot close fixture directory: $!";
die "Expected 21 input archives\n" unless @names == 21;
my $entries = 0;
for my $name (@names) {
    my $before = open_archive(File::Spec->catfile($input, $name));
    my $after = open_archive(File::Spec->catfile($output, $name));
    my @original = $before->{zip}->members();
    my @actual = $after->{zip}->members();
    die "$name: entry count changed\n" unless @original == @actual;
    for my $position (0 .. $#original) {
        my ($left, $right) = ($original[$position], $actual[$position]);
        die "$name: entry order/name changed\n"
            unless $left->fileName() eq $right->fileName();
        die "$name: timestamp changed\n"
            unless $left->lastModFileDateTime() == $right->lastModFileDateTime();
        die "$name: external attributes changed\n"
            unless $left->externalFileAttributes() == $right->externalFileAttributes();
        die "$name: payload changed\n" unless member_bytes($left) eq member_bytes($right);
        ++$entries;
    }
    close_archive($before);
    close_archive($after);
}
say "PASS: independent Perl verification of 21 archives and $entries entries";
