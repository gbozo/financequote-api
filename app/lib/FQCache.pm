package FQCache;

use strict;
use warnings;

my %cache;
my %access_time;     # LRU tracking: key => last access timestamp
my $ttl = 900;
my $enabled = 1;
my $max_entries = 10000;  # Default max cache entries

sub configure {
    my ($env_ttl, $env_enabled, $env_max) = @_;
    if (defined $env_ttl && $env_ttl =~ /^\d+$/) {
        $ttl = $env_ttl;
    }
    $enabled = defined $env_enabled ? $env_enabled : 1;
    if (defined $env_max && $env_max =~ /^\d+$/ && $env_max > 0) {
        $max_entries = $env_max;
    }
}

sub get {
    my ($key) = @_;
    return undef unless $enabled;
    my $entry = $cache{$key};
    return undef unless $entry;
    my ($expires, $data) = @$entry;
    if (time > $expires) {
        delete $cache{$key};
        delete $access_time{$key};
        return undef;
    }
    $access_time{$key} = time;  # Update LRU timestamp
    return $data;
}

sub set {
    my ($key, $data, $custom_ttl) = @_;
    return unless $enabled;
    
    # Evict if at capacity
    _evict() if scalar(keys %cache) >= $max_entries;
    
    my $expire_ttl = $custom_ttl || $ttl;
    $cache{$key} = [ time + $expire_ttl, $data ];
    $access_time{$key} = time;
}

sub clear {
    %cache = ();
    %access_time = ();
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
    return {
        enabled => $enabled,
        ttl => $ttl,
        entries => $count,
        expired => $expired,
        max_entries => $max_entries,
    };
}

sub _evict {
    my $now = time;
    
    # First pass: remove expired entries
    my @expired;
    for my $key (keys %cache) {
        push @expired, $key if $cache{$key}[0] <= $now;
    }
    delete @cache{@expired};
    delete @access_time{@expired};
    
    # If still at capacity, evict oldest 10% by LRU
    if (scalar(keys %cache) >= $max_entries) {
        my $to_evict = int($max_entries * 0.1) || 1;
        my @sorted = sort { ($access_time{$a} // 0) <=> ($access_time{$b} // 0) } keys %cache;
        my @victims = splice(@sorted, 0, $to_evict);
        delete @cache{@victims};
        delete @access_time{@victims};
    }
}

1;
