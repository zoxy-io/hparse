#!/usr/bin/env perl
#
# Regenerates src/corpus_llhttp.zig from llhttp's markdown test fixtures.
#
#   curl -sSfL https://github.com/nodejs/llhttp/archive/refs/tags/v9.4.3.tar.gz | tar -xz
#   perl tools/extract_llhttp_corpus.pl llhttp-9.4.3/test 1024 > /tmp/body.zig
#
# ...then splice the two arrays under the doc comment already at the top of
# src/corpus_llhttp.zig, which is where the provenance and the deviations are
# written down. Prints a summary of everything it dropped to stderr; read it,
# because a corpus that silently loses entries still looks like a corpus.
#
# Perl rather than Zig because this runs once per llhttp release and is not part
# of any build. It lives outside `paths` in build.zig.zon, like bench/, so it is
# never published or compiled.
#
# The decode below replicates llhttp's test/md-test.ts step for step, and the
# ORDER IS LOAD-BEARING: normalizing line endings before expanding backslash
# escapes is what makes a blank line a CRLF while leaving an explicit `\n` a bare
# LF. Swap those two and every bare-LF rejection case silently becomes an
# accepted one. If you re-point this at a newer llhttp, re-read md-test.ts and
# check these steps still match it.

use strict;
use warnings;

my ($root, $max_len) = @ARGV;
die "usage: $0 <llhttp>/test <max-bytes>\n" unless defined $root && defined $max_len;

my (@req, @res, %seen);
my ($skipped_len, $skipped_hex, $dup) = (0, 0, 0);
my @dropped;

for my $path (sort(glob("$root/request/*.md")), sort(glob("$root/response/*.md"))) {
    (my $short = $path) =~ s|^\Q$root\E/||;
    open(my $fh, '<:raw', $path) or die "$path: $!";
    my @lines = <$fh>;
    close $fh;

    my ($heading, $type, $in, $start, @buf) = ('', '', 0, 0);
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if (!$in) {
            $heading = $1 if $line =~ /^#+\s+(.*?)\s*$/;
            $type = $1 if $line =~ /<!--\s*meta=\{.*?"type"\s*:\s*"([^"]+)".*?\}\s*-->/;
            if ($line =~ /^```http\r?\n$/) { $in = 1; $start = $i + 1; @buf = (); }
            next;
        }
        if ($line !~ /^```\r?\n?$/) { push @buf, $line; next; }

        $in = 0;
        my $s = join('', @buf);

        # --- test/md-test.ts pipeline, in order. See the note above. ---
        $s =~ s/\n$//;                      # remove one trailing newline
        $s =~ s/\\(\r\n|\r|\n)//g;          # drop backslash-escaped newlines
        $s =~ s/\r\n|\r|\n/\r\n/g;          # normalize all line endings to CRLF
        $s =~ s/\\r/\r/g;
        $s =~ s/\\n/\n/g;
        $s =~ s/\\t/\t/g;
        $s =~ s/\\f/\f/g;
        # `\xHH` becomes one byte. JavaScript's String.fromCharCode would produce a
        # UTF-16 code unit that llhttp's runner then UTF-8-encodes, so upstream a
        # high `\xff` is two bytes. One byte is what the fixture author wrote and
        # the more interesting input for a byte-scanning parser; see the header of
        # src/corpus_llhttp.zig. Anything above 0xff is refused rather than folded.
        my $bad_hex = 0;
        $s =~ s/\\x([0-9a-fA-F]+)/my $v = hex($1); $bad_hex = 1 if $v > 255; chr($v & 0xff)/ge;
        $s =~ s/\\([0-7]{1,3})/chr(oct($1) & 0xff)/ge;

        if ($bad_hex) {
            $skipped_hex++;
            push @dropped, "$short:$start — hex escape above 0xff";
            next;
        }
        if (length($s) > $max_len) {
            $skipped_len++;
            push @dropped, sprintf("%s:%d — %d bytes, over the %d cap", $short, $start, length($s), $max_len);
            next;
        }
        next if $s eq '';
        if ($seen{$s}++) { $dup++; next; }

        my $entry = { text => $s, src => "$short:$start", name => $heading };
        if    ($type =~ /^request/)  { push @req, $entry }
        elsif ($type =~ /^response/) { push @res, $entry }
        else { die "unknown meta type '$type' at $short:$start\n" }
    }
}

sub zig_literal {
    my ($s) = @_;
    my $out = '';
    for my $c (split //, $s) {
        my $o = ord($c);
        if    ($c eq '\\') { $out .= '\\\\' }
        elsif ($c eq '"')  { $out .= '\\"' }
        elsif ($c eq "\r") { $out .= '\\r' }
        elsif ($c eq "\n") { $out .= '\\n' }
        elsif ($c eq "\t") { $out .= '\\t' }
        elsif ($o >= 0x20 && $o < 0x7f) { $out .= $c }
        else { $out .= sprintf('\\x%02x', $o) }
    }
    return $out;
}

sub emit {
    my ($name, $list) = @_;
    print "pub const $name = [_][]const u8{\n";
    for my $e (@$list) {
        (my $n = $e->{name}) =~ s/\s+/ /g;
        print "    // $e->{src} — $n\n";
        print '    "' . zig_literal($e->{text}) . "\",\n";
    }
    print "};\n";
    return scalar @$list;
}

my $nreq = emit('requests', \@req);
print "\n";
my $nres = emit('responses', \@res);

printf STDERR "requests: %d\nresponses: %d\n", $nreq, $nres;
printf STDERR "dropped: %d over-length, %d bad hex escape, %d exact duplicates\n",
    $skipped_len, $skipped_hex, $dup;
print STDERR "  $_\n" for @dropped;
