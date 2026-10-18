#!/usr/bin/env perl
# Compare the CPU traces from Questa (build/questa/core, build/questa/pipe)
# with XSim's (build/xsim_core, build/xsim_pipe), file for file: every retired
# instruction, bus request and response, reset marker, and the final memory dump.
#
#     perl scripts/compare_sim_traces.pl [--out build/questa/trace_compare.json]
#
# Both sets must come from the same sources and the same regression matrices
# (scripts/run_questa.ps1 -Only cores, and the core part of scripts/regress.ps1).
# Prints TRACES_IDENTICAL and exits 0, or TRACES_DIFFER and exits 1.
use strict;
use warnings;
use FindBin;
use File::Spec;
use Getopt::Long;
use JSON::PP;

my $root = File::Spec->rel2abs("$FindBin::Bin/..");
my $out = 'build/questa/trace_compare.json';
GetOptions('out=s' => \$out) or die "usage: $0 [--out FILE]\n";

my @pairs = (['multicycle', 'build/questa/core', 'build/xsim_core'],
             ['pipeline',   'build/questa/pipe', 'build/xsim_pipe']);

# File contents with CRLF line endings read as LF.
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    $text =~ s/\r\n/\n/g;
    return $text;
}

my (%report, $failed);
for my $pair (@pairs) {
    my ($core, $questa, $xsim) = @$pair;
    my @files = ((sort glob("$root/$questa/*.csv")), (sort glob("$root/$questa/*.csv.mem")));
    die "No Questa traces in $questa\n" unless @files;
    my ($same, $lines, @differ, @missing) = (0, 0);
    for my $file (@files) {
        my ($name) = $file =~ m{([^/]+)$};
        my $other = "$root/$xsim/$name";
        unless (-e $other) { push @missing, $name; next; }
        my ($a, $b) = (slurp($file), slurp($other));
        if ($a eq $b) {
            $same++;
            # trace lines: every line but the CSV header
            $lines += ($a =~ tr/\n//) - 1 if $name =~ /\.csv$/;
        } else {
            push @differ, $name;
        }
    }
    my $traces = grep { /\.csv$/ } @files;
    $report{$core} = {files => scalar @files, traces => $traces, identical => $same, trace_lines => $lines,
                      differ => \@differ, missing => \@missing};
    printf "%s: %d of %d files identical (%d traces, %d trace lines); %d differ, %d missing in XSim\n",
        $core, $same, scalar @files, $traces, $lines, scalar @differ, scalar @missing;
    $failed ||= @differ || @missing;
}

open my $fh, '>', "$root/$out" or die "cannot write $out: $!\n";
print $fh JSON::PP->new->canonical->pretty->encode(\%report);
close $fh;
print $failed ? "TRACES_DIFFER\n" : "TRACES_IDENTICAL\n";
exit($failed ? 1 : 0);
