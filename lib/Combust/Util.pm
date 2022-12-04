package Combust::Util;
use warnings;
use strict;
use utf8;
use base qw(Exporter);
use Carp qw(croak);
use HTML::Entities qw(encode_entities);

our @EXPORT_OK = qw(
    run
    utf8_safe
    escape_html
);

sub run {
    my @ar    = @_;
    my $parms = ref $ar[-1] eq "HASH" ? pop @ar : {};

    print "Running: ", join(" ", @ar), "\n" unless $parms->{silent};

    return 1 if system(@ar) == 0;

    my $exit_value = $? >> 8;
    return 0
      if $parms->{fail_silent_if}
      && $exit_value == $parms->{fail_silent_if};

    my $msg = "system @ar failed: $exit_value ($?)";
    croak($msg) unless $parms->{failok};
    print "$msg\n";
    return 0;
}

sub utf8_safe {
    my $text = shift;
    return unless defined $text;
    $text = Encode::decode("windows-1252", $text)
      unless utf8::is_utf8($text)
      or utf8::decode($text);
    return $text;
}

sub escape_html {
    my $string = shift;
    return encode_entities($string, '<>&"'); # how can we encode everything without messing up UTF8?
}

1;
