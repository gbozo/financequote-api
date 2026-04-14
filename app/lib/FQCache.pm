package FQCache;

use strict;
use warnings;

my %cache;
my $ttl = 900;
my $enabled = 1;

sub configure {
    my ($env_ttl, $env_enabled) = @_;
    $ttl = $env_ttl // 900 if $env_ttl && $env_ttl =~ /^\d+$/;
    $enabled = $env_enabled // 1;
}

sub get {
    my ($key) = @_;
    return undef unless $enabled;
    my $entry = $cache{$key};
    return undef unless $entry;
    my ($expires, $data) = @$entry;
    if (time > $expires) {
        delete $cache{$key};
        return undef;
    }
    return $data;
}

sub set {
    my ($key, $data, $custom_ttl) = @_;
    return unless $enabled;
    my $expire_ttl = $custom_ttl || $ttl;
    $cache{$key} = [ time + $expire_ttl, $data ];
}

sub clear {
    %cache = ();
}

sub stats {
    my $now = time;
    my $count = 0;
    my $expired = 0;
    foreach my $key (keys %cache) {
        my $entry = $cache{$key};
        if ($entry->[0] > $now) {
            $count++;
        } else {
            $expired++;
        }
    }
    return { enabled => $enabled, ttl => $ttl, entries => $count, expired => $expired };
}

1;