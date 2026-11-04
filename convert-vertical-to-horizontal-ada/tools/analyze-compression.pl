use 5.040;
use JSON::PP qw(decode_json encode_json);
use Epub::Convert::VerticalToHorizontal::Archive qw(open_archive close_archive);
use File::Spec;

# Emit anonymous size diagnostics only. Filenames and member paths never leave
# the external reports supplied by the caller.
sub report ($path) {
    open my $file, '<:raw', $path or die 'Cannot open report';
    local $/;
    return decode_json(<$file>);
}
my ($expected_path, $actual_path, $input) = @ARGV;
my $expected = report($expected_path);
my $actual = report($actual_path);
my %expected = map { $_->{Book} => $_ } @$expected;
my @losses;
for my $index (0 .. $#$actual) {
    my $right = $actual->[$index];
    my $left = $expected{$right->{Book}} or die 'Missing reference record';
    my $before = open_archive($left->{Output});
    my $after = open_archive($right->{Output});
    my @x = $before->{zip}->members();
    my @y = $after->{zip}->members();
    my $source = defined($input) ? open_archive(File::Spec->catfile($input,$right->{Book})) : undef;
    my @original = $source ? $source->{zip}->members() : ();
    die 'Entry count differs' unless @x == @y;
    my ($expected_bytes, $actual_bytes) = (0, 0);
    my @entries;
    for my $position (0 .. $#x) {
        my ($a, $b) = ($x[$position], $y[$position]);
        die 'Entry order differs' unless $a->fileName eq $b->fileName;
        $expected_bytes += $a->compressedSize;
        $actual_bytes += $b->compressedSize;
        next unless $b->compressedSize > $a->compressedSize;
        my $kind = $b->fileName =~ /\.(css|xhtml|html|xml|opf|ncx|jpg|jpeg|png|gif|svg|ttf|otf|woff2?)\z/i
            ? lc $1 : 'other';
        push @entries, { entry => $position, kind => $kind, bytes => $b->uncompressedSize,
            expected => $a->compressedSize, actual => $b->compressedSize,
            original => $source ? $original[$position]->compressedSize : undef,
            original_method => $source ? $original[$position]->compressionMethod : undef,
            changed => scalar(grep { $_ eq $b->fileName } @{$right->{ChangedEntries}}) ? 1 : 0 };
    }
    push @losses, { book => $index, delta => $actual_bytes-$expected_bytes, entries => \@entries }
        if $actual_bytes > $expected_bytes;
    close_archive($before);
    close_archive($after);
    close_archive($source) if $source;
}
say encode_json({ larger_books => \@losses });
