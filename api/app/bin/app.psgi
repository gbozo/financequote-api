#!/usr/bin/perl
# FinanceQuote API - PSGI Entry Point
# Wraps Finance::Quote Perl module as a REST API

use strict;
use warnings;
use utf8;

# Finance::Quote is now installed via CPAN, no local lib needed

use Plack::Builder;
use Finance::Quote;

# ============================================
# In-Memory Cache Module
# ============================================

{
    package FQCache;

    use strict;
    use warnings;

    # Cache storage: key => [expires_at, data]
    my %cache;
    my $ttl = 900;  # Default 15 minutes
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
}

# ============================================
# API Application
# ============================================

{
    package FQAPI;

    use strict;
    use warnings;
    use JSON::XS qw(encode_json);

    # Read cache configuration from environment
    my $FQ_CACHE_TTL = $ENV{'FQ_CACHE_TTL'} // 900;  # Default 15 minutes
    my $FQ_CACHE_ENABLED = $ENV{'FQ_CACHE_ENABLED'} // 1;
    FQCache::configure($FQ_CACHE_TTL, $FQ_CACHE_ENABLED);

    # Read configuration from environment
    my $FQ_CURRENCY = $ENV{'FQ_CURRENCY'} // '';
    
    # All supported API keys from environment
    my $ALPHAVANTAGE_API_KEY = $ENV{'ALPHAVANTAGE_API_KEY'} // '';
    my $TWELVEDATA_API_KEY = $ENV{'TWELVEDATA_API_KEY'} // '';
    my $FINANCEAPI_API_KEY = $ENV{'FINANCEAPI_API_KEY'} // '';
    my $STOCKDATA_API_KEY = $ENV{'STOCKDATA_API_KEY'} // '';
    my $FIXER_API_KEY = $ENV{'FIXER_API_KEY'} // '';
    my $OPENEXCHANGE_API_KEY = $ENV{'OPENEXCHANGE_API_KEY'} // '';
    my $CURRENCYFREAKS_API_KEY = $ENV{'CURRENCYFREAKS_API_KEY'} // '';
    
    # Build Finance::Quote with configuration
    my @quoter_args = ();
    
    # Configure modules with their API keys
    if ($ALPHAVANTAGE_API_KEY) {
        push @quoter_args, 'AlphaVantage', { API_KEY => $ALPHAVANTAGE_API_KEY };
    }
    if ($TWELVEDATA_API_KEY) {
        push @quoter_args, 'TwelveData', { API_KEY => $TWELVEDATA_API_KEY };
    }
    if ($FINANCEAPI_API_KEY) {
        push @quoter_args, 'FinanceAPI', { API_KEY => $FINANCEAPI_API_KEY };
    }
    if ($STOCKDATA_API_KEY) {
        push @quoter_args, 'StockData', { API_KEY => $STOCKDATA_API_KEY };
    }
    if ($FIXER_API_KEY) {
        push @quoter_args, 'Fixer', { API_KEY => $FIXER_API_KEY };
    }
    if ($OPENEXCHANGE_API_KEY) {
        push @quoter_args, 'OpenExchange', { API_KEY => $OPENEXCHANGE_API_KEY };
    }
    if ($CURRENCYFREAKS_API_KEY) {
        push @quoter_args, 'CurrencyFreaks', { API_KEY => $CURRENCYFREAKS_API_KEY };
    }
    if ($FQ_CURRENCY) {
        $ENV{'FQ_CURRENCY'} = $FQ_CURRENCY;
    }
    
    my $quoter = Finance::Quote->new(@quoter_args);

    # Get current timestamp in ISO format
    sub get_timestamp {
        my ($sec,$min,$hour,$mday,$mon,$year) = gmtime(time());
        $mon += 1;
        $year += 1900;
        return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $year, $mon, $mday, $hour, $min, $sec);
    }

    # ----- Helper: Build JSON response -----
    sub json_response {
        my $status = shift;
        my $data = shift;
        my $code = shift // 200;
        
        my $ts = get_timestamp();
        my $json_text = '{';
        my @pairs;
        push @pairs, '"status":"' . $status . '"';
        push @pairs, '"data":' . encode_json($data);
        push @pairs, '"timestamp":"' . $ts . '"';
        $json_text .= join(',', @pairs) . '}';
        
        return [ $code, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ $json_text ] ];
    }

    sub error_response {
        my $code = shift;
        my $message = shift;
        my $details = shift // '';
        
        my $ts = get_timestamp();
        my $json_text = '{';
        my @pairs;
        push @pairs, '"status":"error"';
        push @pairs, '"error":' . encode_json({ code => $code, message => $message, details => $details });
        push @pairs, '"timestamp":"' . $ts . '"';
        $json_text .= join(',', @pairs) . '}';
        
        return [ $code, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ $json_text ] ];
    }

    # ----- Routes -----

    # 1. Health Check
    sub handle_health {
        my $cache_stats = FQCache::stats();
        return json_response('success', { 
            service => 'FinanceQuote API', 
            version => '1.69',
            cache => $cache_stats,
        });
    }

    # 2. List Available Methods
    sub handle_methods {
        my @methods = @Finance::Quote::MODULES;
        return json_response('success', { methods => \@methods });
    }

    # 3. Fetch Quotes - GET /quote/:symbols
    sub handle_quote {
        my ($symbols, $params) = @_;
        
        # Build cache key
        my $method = $params->{method} || 'yahoojson';
        my $currency = $params->{currency} || '';
        my $cache_key = "quote:${symbols}:${method}:${currency}";
        
        # Check cache
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;
        
        my @syms = split(/,/, $symbols);
        
        # Set currency if specified
        $quoter->{currency} = $currency if $currency;
        
        # Fetch quotes
        my %quotes = $quoter->fetch($method, @syms);
        
        # Process and normalize results
        my %result;
        foreach my $sym (@syms) {
            my $exists = 0;
            foreach my $key (keys %quotes) {
                my ($s, $attr) = split(/$;/, $key, 2);
                next unless $s eq $sym;
                $exists = 1;
                $result{$sym}{$attr} = $quotes{$key};
            }
            # If no data at all, mark as failed
            unless ($result{$sym}) {
                $result{$sym} = {
                    symbol => $sym,
                    success => 0,
                    errormsg => 'No data returned for symbol',
                };
            }
        }
        
        my $response = json_response('success', \%result);
        FQCache::set($cache_key, $response);
        return $response;
    }

# 4. Currency Conversion
    sub handle_currency {
        my ($from, $to, $params) = @_;
        
        # Build cache key
        my $cache_key = "currency:${from}:${to}";
        
        # Check cache
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;
        
        # For currency, we can try alphavantage (needs API key) or other methods
        if ($ALPHAVANTAGE_API_KEY) {
            my @pairs = ("$from$to");
            my %quotes = $quoter->fetch('alphavantage', @pairs);
            
            my $rate;
            foreach my $k (keys %quotes) {
                my $v = $quotes{$k};
                # Handle both hash ref and string values
                if (ref($v) eq 'HASH') {
                    $rate = $v->{close} || $v->{last} || $v->{rate};
                } elsif (!ref($v) && $v =~ /^-?[\d.]+$/) {
                    $rate = $v;
                }
                last if $rate;
            }
            
            if ($rate && $rate =~ /^-?[\d.]+$/) {
                my $response = json_response('success', {
                    from => $from,
                    to   => $to,
                    rate => $rate + 0,
                });
                FQCache::set($cache_key, $response);
                return $response;
            }
        }
        
        # Fallback: Try general approach with FQ_CURRENCY setting
        my @pairs = ("$from$to");
        my %quotes = $quoter->fetch('yahoojson', @pairs);
        
        my $rate;
        foreach my $k (keys %quotes) {
            my $v = $quotes{$k};
            if (ref($v) eq 'HASH' && $v->{success}) {
                my $got_currency = $v->{currency} // '';
                if ($got_currency eq $to || $v->{last}) {
                    $rate = $v->{close} || $v->{last};
                    last if $rate;
                }
            } elsif (!ref($v) && $v =~ /^-?[\d.]+$/) {
                $rate = $v;
                last if $rate;
            }
        }
        
        # Try Currencies module as fallback
        unless ($rate) {
            %quotes = $quoter->fetch('Currencies', @pairs);
            my $key = "${from}${to}";
            my $v = $quotes{$key};
            if (ref($v) eq 'HASH') {
                $rate = $v->{last} || $v->{rate};
            } elsif (!ref($v) && $v =~ /^-?[\d.]+$/) {
                $rate = $v;
            }
        }
        
        if ($rate && $rate =~ /^-?[\d.]+$/) {
            my $response = json_response('success', {
                from => $from,
                to   => $to,
                rate => $rate + 0,
            });
            FQCache::set($cache_key, $response);
            return $response;
        } else {
            return error_response(400, "Cannot convert $from to $to", "Exchange rate not available. Try setting ALPHAVANTAGE_API_KEY.");
        }
    }

    # 5. Direct fetch with method
    sub handle_fetch {
        my ($method, $symbols, $params) = @_;
        
        # Validate method
        my @methods = @{ $Finance::Quote::MODULES };
        my %method_map;
        @method_map{@methods} = ();
        
        unless (exists $method_map{lc($method)}) {
            return error_response(400, "Unknown method: $method", "Use /api/v1/methods to see available methods");
        }
        
        # Build cache key
        my $cache_key = "fetch:${method}:${symbols}";
        
        # Check cache
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;
        
        my @syms = split(/,/, $symbols);
        my %quotes = $quoter->fetch($method, @syms);
        
        # Process results
        my %result;
        foreach my $sym (@syms) {
            foreach my $key (keys %quotes) {
                my ($s, $attr) = split(/$;/, $key, 2);
                next unless $s eq $sym;
                $result{$sym}{$attr} = $quotes{$key};
            }
        }
        
        my $response = json_response('success', \%result);
        FQCache::set($cache_key, $response);
        return $response;
    }
}

# ============================================
# Plack Application Builder
# ============================================

sub {
    my $env = shift;
    my $path = $env->{PATH_INFO} // '/';
    my $method = $env->{REQUEST_METHOD} // 'GET';
    my @params = split(/&/, $env->{QUERY_STRING} // '');
    my %params;
    foreach my $p (@params) {
        my ($k, $v) = split(/=/, $p, 2);
        $params{$k} = $v if $k;
    }
    
    # CORS preflight
    if ($method eq 'OPTIONS') {
        return [ 200, [ 
            'Content-Type' => 'application/json',
            'Access-Control-Allow-Origin' => '*',
            'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers' => 'Content-Type',
        ], [] ];
    }
    
    # API Authentication check
    my $auth_keys = $ENV{'API_AUTH_KEYS'} // '';
    if ($auth_keys) {
        my @keys = split(/,/, $auth_keys);
        my $auth_header = $env->{HTTP_AUTHORIZATION} // '';
        my $provided_key = '';
        
        if ($auth_header =~ /^Bearer\s+(.+)$/i) {
            $provided_key = $1;
        }
        
        my $authorized = 0;
        foreach my $key (@keys) {
            $key =~ s/^\s+|\s+$//g;  # trim whitespace
            if ($key && $key eq $provided_key) {
                $authorized = 1;
                last;
            }
        }
        
        unless ($authorized) {
            return FQAPI::error_response(401, 'Unauthorized', 'Invalid or missing API key. Set API_AUTH_KEYS environment variable.');
        }
    }
    
    # Route: /api/v1/health
    if ($path eq '/api/v1/health') {
        return FQAPI::handle_health();
    }
    
    # Route: /api/v1/methods
    if ($path eq '/api/v1/methods') {
        return FQAPI::handle_methods();
    }
    
    # Route: /api/v1/quote/:symbols
    if ($path =~ m{^/api/v1/quote/([^/]+)$}) {
        return FQAPI::handle_quote($1, \%params);
    }
    
    # Route: /api/v1/currency/:from/:to
    if ($path =~ m{^/api/v1/currency/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_currency($1, $2, \%params);
    }
    
    # Route: /api/v1/fetch/:method/:symbols
    if ($path =~ m{^/api/v1/fetch/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_fetch($1, $2, \%params);
    }
    
    # Serve static files (documentation)
    if ($path eq '/' || $path eq '/index.html' || $path eq '/docs' || $path eq '/docs/') {
        my $html = do { local $/; open my $fh, '<', '/app/public/index.html'; <$fh> };
        return [ 200, [ 'Content-Type' => 'text/html', 'Access-Control-Allow-Origin' => '*' ], [ $html ] ];
    }
    
    # Default: 404 Not Found
    return FQAPI::error_response(404, "Not Found", "Path $path not found");
};