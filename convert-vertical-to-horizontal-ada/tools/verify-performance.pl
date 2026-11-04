use 5.040;
use JSON::PP qw(decode_json encode_json);
use Digest::SHA;
use Epub::Convert::VerticalToHorizontal::Archive qw(open_archive close_archive member_bytes);
use Epub::Convert::VerticalToHorizontal::Files qw(open_read);
use File::Spec;

sub report ($path) {
    open my $file, '<:raw', $path or die 'Cannot open report';
    local $/;
    return decode_json(<$file>);
}
sub hash ($path) {
    my $file = open_read($path);
    my $sha = Digest::SHA->new(256)->addfile($file);
    close $file or die 'Cannot close file';
    return uc $sha->hexdigest;
}
my ($expected_path, $actual_path, $input, $quality_gate) = @ARGV;
$quality_gate //= 'Report';
my $expected = report($expected_path);
my $actual = report($actual_path);
die 'Record count differs' unless @$expected == @$actual;
my %expected = map { $_->{Book} => $_ } @$expected;
my $entries = 0;
my ($compressed_expected, $compressed_actual, $larger_books) = (0,0,0);
for my $index (0 .. $#$actual) {
    my $right = $actual->[$index];
    my $left = $expected{$right->{Book}} or die "Missing record $index";
    die "Conversion error $index" if $right->{Status} eq 'Error';
    for my $key (qw(Status Reason InputBytes InputSHA256 EntriesVerified)) {
        die "Field mismatch $index: $key" if ($left->{$key}//'') ne ($right->{$key}//'');
    }
    die "Patch mismatch $index" if join("\0",@{$left->{ChangedEntries}}) ne join("\0",@{$right->{ChangedEntries}});
    die "Source changed $index" unless hash(File::Spec->catfile($input,$right->{Book})) eq $left->{InputSHA256};
    for my $record ($left,$right) {
        die "Output hash $index" unless hash($record->{Output}) eq $record->{OutputSHA256};
        my $file = open_read($record->{Output});
        die "Output size $index" unless -s $file == $record->{OutputBytes};
        close $file or die 'Cannot close output';
        die "Preserved copy $index" if $record->{Status} eq 'Preserved' && $record->{InputSHA256} ne $record->{OutputSHA256};
    }
    my $before = open_archive($left->{Output});
    my $after = open_archive($right->{Output});
    my @x = $before->{zip}->members();
    my @y = $after->{zip}->members();
    die "Entry count $index" unless @x == @y;
    my ($book_expected, $book_actual) = (0,0);
    for my $position (0..$#x) {
        my ($a,$b)=($x[$position],$y[$position]);
        die "Entry mismatch $index/$position" unless
            $a->fileName eq $b->fileName &&
            $a->lastModFileDateTime == $b->lastModFileDateTime &&
            $a->externalFileAttributes == $b->externalFileAttributes &&
            member_bytes($a) eq member_bytes($b);
        ++$entries;
        $book_expected += $a->compressedSize;
        $book_actual += $b->compressedSize;
    }
    $compressed_expected += $book_expected;
    $compressed_actual += $book_actual;
    ++$larger_books if $book_actual > $book_expected;
    close_archive($before); close_archive($after);
}
say 'PASS books=',scalar(@$actual),' entries=',$entries;
say 'METRICS ',encode_json({compressed_expected=>$compressed_expected,
    compressed_actual=>$compressed_actual,larger_books=>$larger_books});
die 'Per-book compression quality gate failed' if $quality_gate eq 'PerBook' && $larger_books;
die 'Aggregate compression quality gate failed' if $quality_gate eq 'Aggregate' && $compressed_actual>$compressed_expected;
