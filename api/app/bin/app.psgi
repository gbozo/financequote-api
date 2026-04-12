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
# API Application
# ============================================

{
    package FQAPI;

    use strict;
    use warnings;
    use JSON::XS qw(encode_json);

    my $quoter = Finance::Quote->new();

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
        return json_response('success', { service => 'FinanceQuote API', version => '1.68' });
    }

    # 2. List Available Methods
    sub handle_methods {
        my @methods = @Finance::Quote::MODULES;
        return json_response('success', { methods => \@methods });
    }

    # 3. Fetch Quotes - GET /quote/:symbols
    sub handle_quote {
        my ($symbols, $params) = @_;
        
        my @syms = split(/,/, $symbols);
        my $method = $params->{method} || 'yahoojson';
        my $currency = $params->{currency} || '';
        
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
        
        return json_response('success', \%result);
    }

    # 4. Currency Conversion
    sub handle_currency {
        my ($from, $to, $params) = @_;
        
        # Try to get currency rate using YahooJSON (supports some pairs)
        # Finance::Quote can fetch currencies via various methods
        my @pairs = ("$from$to");
        
        # Try fetching currency via a stock quote approach (some sources support it)
        my %quotes = $quoter->fetch('yahoojson', @pairs);
        
        my $rate;
        # Check various key formats returned by different modules
        my $key = "${from}${to}";
        
        # Try different key formats
        foreach my $k (keys %quotes) {
            if ($k =~ /^${from}$to$/i || $k =~ /^${from}.*$to$/i) {
                $rate = $quotes{$k}{last} || $quotes{$k}{rate} || $quotes{$k};
                last if $rate;
            }
        }
        
        # If not found, try currency specific modules
        unless ($rate) {
            # Try fetching from Currencies module
            %quotes = $quoter->fetch('Currencies', @pairs);
            $rate = $quotes{$key}{last} || $quotes{$key}{rate};
        }
        
        if ($rate && $rate =~ /^-?[\d.]+$/) {
            return json_response('success', {
                from => $from,
                to   => $to,
                rate => $rate + 0,
            });
        } else {
            return error_response(400, "Cannot convert $from to $to", "Exchange rate not available. Currency conversion requires external API or may not be supported for this pair.");
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
        
        return json_response('success', \%result);
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