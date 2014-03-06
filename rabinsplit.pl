#!/usr/bin/perl
#
# (C) 2010 Nathaniel Wesley Filardo <nwf@cs.jhu.edu>
#
# Rabin Fingerprint stream/file splitter
#
# This is intended as a pre-processing stage to content-addressed storage
# systems (e.g. Venti).  Either take a large file and split it, or make a
# tarball and split that, then vac up the resulting files.  The idea is that
# we find stable parts of the files between signatures, so even if the
# offsets change, we'll recover.
#
# Ideally, set --max equal to (a positive integer multiple of) the block
# size of vac.
#
# For technical discussion, see
# http://gsoc.cat-v.org/people/mjl/blog/2007/08/06/1_Rabin_fingerprints/
# and
# Center for Research in Computing Technology, Harvard University. Tech
# Report TR-CSE-03-01.  http://www.xmailserver.org/rabin.pdf

use strict;
use warnings;

use Getopt::Long;

my $WINDOW = 31;                # Rabin fingerprinting window (bytes)
my $PRIME = 5;                  # Prime multiplier
my $MOD = 2**12;                # Modulus (expected block size!)
my $CHUNKSIZE_MAX = 0;          # Split at least this often
my $CHUNKSIZE_MIN = 0;          # Split at most  this often
my $CISHIFT = 0;                # Another possible knob (for testing)
my $INFILE = "/dev/fd/0";       # Input file name
my $OUTPFX = undef;             # Output prefix
my $OUTSWD = 8;                 # Output width
my $FINGERPRINT = $MOD-1;       # Which value from Z_{$MOD} are we using?
my $WRITE = 1;                  # Disable output production; merely count chunks
my $VERBOSE = 0;

my %OPTIONS = (
      'in=s' => \$INFILE
    , 'prefix=s' => \$OUTPFX
    , 'swidth=i' => \$OUTSWD
    , 'write!' => \$WRITE

    # Parameters to slicing and dicing
    , 'max=i' => \$CHUNKSIZE_MAX
    , 'min=i' => \$CHUNKSIZE_MIN
    , 'mod=i' => \$MOD
    , 'verbose+' => \$VERBOSE

    # Less likely to fiddle with these
    , 'cishift=i' => \$CISHIFT
    , 'fingerprint=i' => \$FINGERPRINT
    , 'prime=i' => \$PRIME
    , 'window=i' => \$WINDOW
    );
GetOptions(%OPTIONS) or die $!;

die "Window too small!" if $WINDOW < 2;
die "Fingerprint out of range!" if $FINGERPRINT < 0 or $FINGERPRINT >= $MOD;
die "Don't set --no-write and --prefix." if defined $OUTPFX and not $WRITE;
die "Need input file." if not defined $INFILE;
$OUTPFX = "x" if not defined $OUTPFX;

# Compute the shift-out table; we do this in iterated maps to avoid overflow
my $shiftout;
@$shiftout = map { ($_+$CISHIFT)%$MOD } (0..255);
for my $i (1..$WINDOW-1) {
        @$shiftout = map { ($_*$PRIME)%$MOD } @$shiftout;
}    

my @buf = ( );
my $sum = 0;
my $chunksize = 0;
my $curr_outn = 0; 
my $curr_outf = undef;

sub dosplit () {
    (close $curr_outf or die) if defined $curr_outf;
    $chunksize = 0;
    (open ($curr_outf, ">:bytes", $OUTPFX.(sprintf "%0${OUTSWD}x", $curr_outn))
            or die "...: $!")
        if $WRITE;
    $curr_outn++;
}

my $bytes_proc = 0;
sub procbyte ($) {
    my ($_) = @_;

    $_ += $CISHIFT;

    push @buf, $_;
    $sum *= $PRIME;
    $sum += $_;
    $sum %= $MOD;
    $bytes_proc++;
    $chunksize++;
    if($CHUNKSIZE_MAX != 0 and $chunksize == $CHUNKSIZE_MAX) {
        print STDERR "CHUNKFORCE \@$bytes_proc ($chunksize)\n" if $VERBOSE;
        dosplit();
    }
    if($sum == $FINGERPRINT) {
        if ($chunksize > $CHUNKSIZE_MIN) {
            print STDERR "CHUNKCHECK \@$bytes_proc ($chunksize)\n" if $VERBOSE;
            dosplit();
        } else {
            print STDERR "CHUNKSKIP  \@$bytes_proc ($chunksize)\n" if $VERBOSE;
        }
    }
    print STDERR "$_ : $sum : ", (join "-", @buf), "\n" if $VERBOSE > 3;
    print $curr_outf (chr $_) if $WRITE;
}

my $if;
open( $if, "<:bytes", $INFILE ) or die "Can't open '$INFILE': $!";

# Get things started.
dosplit();

while(scalar @buf < $WINDOW) {
    my $r = read($if, $_, 1);
    last if not defined $r or $r < 1;
    $_ = ord;
    procbyte($_);
}

while(1 == read($if, $_, 1)) {
    $_ = ord;
    my $s = $$shiftout[(shift @buf) - $CISHIFT];
    $sum -= $s;
    $sum %= $MOD;
    procbyte($_);
}

print STDERR "CHUNKEOF   \@$bytes_proc ($chunksize)\n" if $VERBOSE;
printf "DONE  bytes=%d maxchunk='%0${OUTSWD}x'\n", $bytes_proc, $curr_outn-1 if $VERBOSE;
