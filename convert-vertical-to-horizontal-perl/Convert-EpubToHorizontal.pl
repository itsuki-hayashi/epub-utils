#!/usr/bin/env perl

use 5.044;
use utf8;

use English qw(-no_match_vars);
use FindBin qw($RealBin);
use lib "$RealBin/local/lib/perl5", "$RealBin/lib";

use Epub::Horizontal::CLI   qw(run_cli);
use Epub::Horizontal::Files qw(command_arguments);

if ( $OSNAME eq 'MSWin32' ) {
    require Win32;
    Win32::SetConsoleCP(65001);
    Win32::SetConsoleOutputCP(65001);
}
binmode STDOUT, ':encoding(UTF-8)' or die "Cannot configure standard output: $OS_ERROR\n";
binmode STDERR, ':encoding(UTF-8)' or die "Cannot configure standard error: $OS_ERROR\n";

my $status;
try {
    my @arguments = command_arguments();
    $status = run_cli( \@arguments, $RealBin );
}
catch ($error) {
    print {*STDERR} $error or die "Cannot print failure: $OS_ERROR\n";
    $status = 1;
}
exit $status;

__END__

=head1 NAME

Convert-EpubToHorizontal.pl - Preserve horizontal EPUBs and convert vertical text

=head1 SYNOPSIS

    perl Convert-EpubToHorizontal.pl --analyze-only
    perl Convert-EpubToHorizontal.pl --output-directory horizontal-perl --report-path perl-report.json
    perl Convert-EpubToHorizontal.pl --help

=head1 DESCRIPTION

Requires Perl 5.44 and the workspace-local dependencies declared in cpanfile.
See README.md for installation, verification and layout limitations.

=cut
