#!/usr/bin/perl
# FinanceQuote API - PSGI Entry Point
# Wraps Finance::Quote Perl module as a REST API
#
# Routing and middleware live in FQRouter.pm.
# This file contains only handler business logic (FQAPI package).

use strict;
use warnings;
use utf8;
use JSON::XS qw(encode_json decode_json);

use lib 'lib';
use FQCache;
use FQDB;
use FQUtils;
use FQRouter;
use FQMCP;
use FQChart;

use Plack::Builder;
use Finance::Quote;

# ============================================
# API Application - Handler Business Logic
# ============================================

{
    package FQAPI;

    use strict;
    use warnings;

    # Import utility functions
    sub get_timestamp { FQUtils::get_timestamp() }
    sub standard_headers { FQUtils::standard_headers() }
    sub build_cache_key { FQUtils::build_cache_key(@_) }
    sub process_quote_results { FQUtils::process_quote_results(@_) }
    sub url_decode { FQUtils::url_decode(@_) }
    sub json_response { FQUtils::json_response(@_) }
    sub error_response { FQUtils::error_response(@_) }
    sub jsonrpc_response { FQUtils::jsonrpc_response(@_) }
    sub jsonrpc_error { FQUtils::jsonrpc_error(@_) }
    sub json_error_response { FQUtils::json_error_response(@_) }
    sub decode_json { JSON::XS::decode_json(@_) }

    # Build method normalization map ONCE at startup
    my %METHOD_MAP;
    {
        my @methods = @Finance::Quote::MODULES;
        $METHOD_MAP{lc($_)} = $_ for @methods;
    }

    sub _normalize_method {
        my ($method) = @_;
        return $METHOD_MAP{lc($method)} // $method;
    }

    # ============================================
    # OpenAPI Route Registrations
    # ============================================

    FQUtils::register_route('/api/v1/health', 'get', {
        summary => 'Health Check',
        description => 'Returns API health status and cache statistics',
        responses => { '200' => { description => 'OK' } },
    });
    FQUtils::register_route('/api/v1/methods', 'get', {
        summary => 'List Available Methods',
        description => 'Returns list of available Finance::Quote fetch methods',
        responses => { '200' => { description => 'OK' } },
    });
    FQUtils::register_route('/api/v1/quote/{symbols}', 'get', {
        summary => 'Fetch Quotes',
        description => 'Fetch stock quotes for given symbols. By default includes company_info from FinanceDatabase (sector, industry, country, website, summary, ISIN, etc.) for each symbol.',
        params => [
            { name => 'symbols', in => 'path', required => 1, type => 'string', description => 'Comma-separated symbols' },
            { name => 'method', in => 'query', type => 'string', description => 'Quote method (default: yahooJSON)' },
            { name => 'currency', in => 'query', type => 'string', description => 'Desired currency (e.g., EUR)' },
            { name => 'enrich', in => 'query', type => 'boolean', description => 'Include company_info from FinanceDatabase (default: true). Set to 0 to disable.' },
        ],
        responses => { '200' => { description => 'Quote data with optional company_info' } },
    });
    FQUtils::register_route('/api/v1/info/{symbol}', 'get', {
        summary => 'Get Symbol Info',
        description => 'Get detailed metadata about a stock symbol. By default includes company_info from FinanceDatabase (sector, industry, country, website, summary, ISIN, etc.).',
        params => [
            { name => 'symbol', in => 'path', required => 1, type => 'string', description => 'Stock symbol' },
            { name => 'method', in => 'query', type => 'string', description => 'Quote method' },
            { name => 'enrich', in => 'query', type => 'boolean', description => 'Include company_info from FinanceDatabase (default: true). Set to 0 to disable.' },
        ],
        responses => { '200' => { description => 'Symbol metadata with optional company_info' } },
    });
    FQUtils::register_route('/api/v1/currency/{from}/{to}', 'get', {
        summary => 'Currency Conversion',
        description => 'Get exchange rate between two currencies',
        params => [
            { name => 'from', in => 'path', required => 1, type => 'string', description => 'Source currency' },
            { name => 'to', in => 'path', required => 1, type => 'string', description => 'Target currency' },
        ],
        responses => { '200' => { description => 'Exchange rate' } },
    });
    FQUtils::register_route('/api/v1/fetch/{method}/{symbols}', 'get', {
        summary => 'Direct Fetch',
        description => 'Fetch quotes using a specific method. By default includes company_info from FinanceDatabase.',
        params => [
            { name => 'method', in => 'path', required => 1, type => 'string', description => 'FQ method name' },
            { name => 'symbols', in => 'path', required => 1, type => 'string', description => 'Symbols' },
            { name => 'enrich', in => 'query', type => 'boolean', description => 'Include company_info from FinanceDatabase (default: true). Set to 0 to disable.' },
        ],
        responses => { '200' => { description => 'Quote data with optional company_info' } },
    });
    FQUtils::register_route('/api/v1/db/stats', 'get', {
        summary => 'Database Statistics',
        description => 'Get row counts for each asset type table',
        responses => { '200' => { description => 'Statistics' } },
    });
    FQUtils::register_route('/api/v1/db/assets', 'get', {
        summary => 'List Asset Types',
        description => 'Get list of available asset types',
        responses => { '200' => { description => 'Asset types' } },
    });
    FQUtils::register_route('/api/v1/db/options/{type}', 'get', {
        summary => 'Filter Options',
        description => 'Get available filter options for an asset type',
        params => [
            { name => 'type', in => 'path', required => 1, type => 'string', description => 'Asset type' },
        ],
        responses => { '200' => { description => 'Filter options' } },
    });
    FQUtils::register_route('/api/v1/search', 'get', {
        summary => 'Search Assets',
        description => 'Search financial assets by name, symbol, or ISIN',
        params => [
            { name => 'q', in => 'query', required => 1, type => 'string', description => 'Search query' },
            { name => 'type', in => 'query', type => 'string', description => 'Asset type filter' },
            { name => 'limit', in => 'query', type => 'integer', description => 'Max results' },
            { name => 'primary', in => 'query', type => 'boolean', description => 'Primary exchanges only' },
        ],
        responses => { '200' => { description => 'Search results' } },
    });
    FQUtils::register_route('/api/v1/lookup/{symbol}', 'get', {
        summary => 'Lookup Symbol',
        description => 'Lookup exact symbol details from database',
        params => [
            { name => 'symbol', in => 'path', required => 1, type => 'string', description => 'Symbol' },
        ],
        responses => { '200' => { description => 'Symbol data' } },
    });
    FQUtils::register_route('/api/v1/filter', 'get', {
        summary => 'Filter Assets',
        description => 'Filter assets by criteria (sector, country, exchange, etc.)',
        params => [
            { name => 'type', in => 'query', required => 1, type => 'string', description => 'Asset type' },
            { name => 'sector', in => 'query', type => 'string' },
            { name => 'country', in => 'query', type => 'string' },
            { name => 'exchange', in => 'query', type => 'string' },
            { name => 'market_cap', in => 'query', type => 'string' },
            { name => 'limit', in => 'query', type => 'integer' },
        ],
        responses => { '200' => { description => 'Filtered results' } },
    });
    FQUtils::register_route('/api/v1/history/{symbol}', 'get', {
        summary => 'Quote History',
        description => 'Get historical quote data for a symbol (recorded from previous fetches)',
        params => [
            { name => 'symbol', in => 'path', required => 1, type => 'string', description => 'Ticker symbol' },
            { name => 'from', in => 'query', type => 'string', description => 'Start date (YYYY-MM-DD)' },
            { name => 'to', in => 'query', type => 'string', description => 'End date (YYYY-MM-DD)' },
            { name => 'limit', in => 'query', type => 'integer', description => 'Max records (default: 365)' },
        ],
        responses => { '200' => { description => 'Historical quote records' } },
    });
    FQUtils::register_route('/api/v1/history', 'get', {
        summary => 'History Overview',
        description => 'Get list of symbols with historical data and date ranges',
        responses => { '200' => { description => 'Symbols with history stats' } },
    });
        FQUtils::register_route('/api/v1/chart/{symbol}', 'get', {
        summary => 'Stock Chart Card',
        description => 'Generate an SVG stock card with price chart, metrics, and company info. Returns SVG image or base64-encoded SVG in JSON.',
        params => [
            { name => 'symbol', in => 'path', required => 1, type => 'string', description => 'Ticker symbol' },
            { name => 'size', in => 'query', type => 'string', description => 'Card size: small (400x250), medium (600x400), large (800x500). Default: medium' },
            { name => 'method', in => 'query', type => 'string', description => 'Quote method (default: yahooJSON)' },
            { name => 'currency', in => 'query', type => 'string', description => 'Currency for prices' },
            { name => 'days', in => 'query', type => 'integer', description => 'Days of history to show (default: 90)' },
            { name => 'format', in => 'query', type => 'string', description => 'Response format: svg (raw SVG), json (base64 in JSON), html (embedded HTML). Default: svg' },
        ],
        responses => { '200' => { description => 'SVG image or JSON with base64 SVG' } },
    });
    FQUtils::register_route('/mcp', 'post', {
        summary => 'MCP Endpoint',
        description => 'Model Context Protocol JSON-RPC 2.0 endpoint. Supports: initialize, tools/list, tools/call, resources/list, resources/read, prompts/list, prompts/get, notifications/initialized. 13 tools, 3 resources, 4 prompts available.',
        responses => { '200' => { description => 'JSON-RPC response' } },
    });
    FQUtils::register_route('/mcp', 'get', {
        summary => 'MCP SSE Endpoint',
        description => 'MCP Server-Sent Events fallback for streaming transport',
        responses => { '200' => { description => 'SSE stream' } },
    });
    FQUtils::register_route('/mcp/sse', 'get', {
        summary => 'MCP SSE Endpoint',
        description => 'MCP Server-Sent Events endpoint for streaming transport',
        responses => { '200' => { description => 'SSE stream' } },
    });

    # ============================================
    # Configuration
    # ============================================

    # Cache configuration (SQLite-backed)
    my $FQ_CACHE_TTL = $ENV{'FQ_CACHE_TTL'} // 900;
    my $FQ_CACHE_ENABLED = $ENV{'FQ_CACHE_ENABLED'} // 1;
    my $FQ_DB_PATH = $ENV{'FQ_DB_PATH'} // '/data/finance_database.db';
    FQCache::configure($FQ_CACHE_TTL, $FQ_CACHE_ENABLED, $FQ_DB_PATH);

    # Initialize quotes history table
    FQDB::init_history_table();

    # Currency configuration
    my $FQ_CURRENCY = $ENV{'FQ_CURRENCY'} // '';

    # Build Finance::Quote with API keys (data-driven)
    my %API_KEY_MODULES = (
        ALPHAVANTAGE_API_KEY   => 'AlphaVantage',
        TWELVEDATA_API_KEY     => 'TwelveData',
        FINANCEAPI_API_KEY     => 'FinanceAPI',
        STOCKDATA_API_KEY      => 'StockData',
        FIXER_API_KEY          => 'Fixer',
        OPENEXCHANGE_API_KEY   => 'OpenExchange',
        CURRENCYFREAKS_API_KEY => 'CurrencyFreaks',
    );

    my @quoter_args;
    for my $env_key (sort keys %API_KEY_MODULES) {
        my $key_val = $ENV{$env_key} // '';
        if ($key_val) {
            push @quoter_args, $API_KEY_MODULES{$env_key}, { API_KEY => $key_val };
        }
    }

    # Set currency BEFORE creating the quoter object (see AGENTS.md gotcha #1)
    $ENV{'FQ_CURRENCY'} = $FQ_CURRENCY if $FQ_CURRENCY;
    my $quoter = Finance::Quote->new(@quoter_args);

    # Keep a reference to AlphaVantage key for currency fallback
    my $ALPHAVANTAGE_API_KEY = $ENV{'ALPHAVANTAGE_API_KEY'} // '';

    # MCP module configuration - pass shared data-fetching functions
    FQMCP::configure(
        fetch_quotes   => \&_fetch_quotes_data,
        fetch_info     => \&_fetch_info_data,
        fetch_currency => \&_fetch_currency_data,
    );

    # ============================================
    # Handlers
    # ============================================

    # 1. Health Check
    sub handle_health {
        my $cache_stats = FQCache::stats();
        return json_response('success', {
            service => 'FinanceQuote API',
            version => $FQUtils::VERSION,
            cache   => $cache_stats,
        });
    }

    # 2. List Available Methods
    sub handle_methods {
        my @methods = @Finance::Quote::MODULES;
        return json_response('success', { methods => \@methods });
    }

    # ============================================
    # DB Enrichment Helper
    # ============================================

    # Enrich a single symbol's data with FinanceDatabase info.
    # Adds a 'company_info' nested object with sector, industry, country,
    # website, summary, etc. from the FinanceDatabase SQLite DB.
    # Returns the DB info hashref (or undef if not found).
    sub _enrich_symbol {
        my ($symbol) = @_;
        return undef unless $symbol;
        my $db_info = eval { FQDB::lookup_symbol($symbol) };
        return undef unless $db_info && ref $db_info eq 'HASH';

        # Remove fields that duplicate live quote data or are redundant
        my %skip = map { $_ => 1 } qw(symbol);
        my %company_info;
        for my $key (keys %$db_info) {
            next if $skip{$key};
            next unless defined $db_info->{$key} && $db_info->{$key} ne '';
            $company_info{$key} = $db_info->{$key};
        }

        return keys %company_info ? \%company_info : undef;
    }

    # Enrich a quote result hash (keyed by symbol) with company_info from DB
    sub _enrich_quotes_result {
        my ($result) = @_;
        return unless $result && ref $result eq 'HASH';

        for my $sym (keys %$result) {
            next unless ref $result->{$sym} eq 'HASH';
            my $info = _enrich_symbol($sym);
            $result->{$sym}{company_info} = $info if $info;
        }
    }

    # Enrich a single info hash with company_info from DB
    sub _enrich_info_result {
        my ($info) = @_;
        return unless $info && ref $info eq 'HASH';
        my $sym = $info->{symbol};
        return unless $sym;

        my $db_info = _enrich_symbol($sym);
        $info->{company_info} = $db_info if $db_info;
    }

    # 3. Fetch Quotes - core logic shared by REST and MCP
    sub _fetch_quotes_data {
        my ($symbols_str, $method, $currency, $enrich) = @_;
        $method = _normalize_method($method || 'YahooJSON');
        $currency //= '';
        $enrich //= 1;  # Enrichment on by default

        my @syms = split(/,/, $symbols_str);
        $quoter->{currency} = $currency if $currency;
        my %quotes = $quoter->fetch($method, @syms);
        my $result = process_quote_results(\%quotes, \@syms);

        # Record to quotes_history (per-symbol per-day)
        eval { FQDB::record_quotes($result, $method) };

        # Enrich with FinanceDatabase company info
        _enrich_quotes_result($result) if $enrich;

        return $result;
    }

    sub handle_quote {
        my ($symbols, $params) = @_;

        my $method = $params->{method} || 'YahooJSON';
        $method = _normalize_method($method);
        my $currency = $params->{currency} || '';
        my $enrich = (!defined $params->{enrich} || $params->{enrich}) ? 1 : 0;
        my $cache_key = build_cache_key('quote', $symbols, $method, $currency, $enrich ? 'e' : '');

        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $result = _fetch_quotes_data($symbols, $method, $currency, $enrich);
        my $response = json_response('success', $result);
        FQCache::set($cache_key, $response);
        return $response;
    }

    # 3b. Symbol Info - core logic shared by REST and MCP
    sub _fetch_info_data {
        my ($symbol, $method, $enrich) = @_;
        $method = _normalize_method($method || 'YahooJSON');
        $enrich //= 1;  # Enrichment on by default

        my %quotes = $quoter->fetch($method, $symbol);
        my $sep = $;;
        my $info = {};

        foreach my $key (keys %quotes) {
            # Use index() not split() to avoid encoding issues with $;
            my $pos = index($key, $sep);
            next if $pos < 0;
            my $s = substr($key, 0, $pos);
            my $attr = substr($key, $pos + 1);
            next unless $s eq $symbol;

            if ($attr =~ /^(name|exchange|cap|year_high|year_low|div|yield|eps|pe|volume|avg_vol|day_range|year_range|currency|pct_change|open|close|high|low|date|time|errormsg|success)$/) {
                $info->{$attr} = $quotes{$key};
            }
        }

        $info->{symbol} = $symbol;

        unless (keys %$info > 1) {
            $info = {
                symbol   => $symbol,
                success  => 0,
                errormsg => 'No data returned for symbol',
            };
        }

        # Record to quotes_history if we got valid data
        if ($info->{success}) {
            eval { FQDB::record_quote($symbol, $info, $method) };
        }

        # Enrich with FinanceDatabase company info
        _enrich_info_result($info) if $enrich;

        return $info;
    }

    sub handle_info {
        my ($symbol, $params) = @_;

        my $method = $params->{method} || 'YahooJSON';
        $method = _normalize_method($method);
        my $enrich = (!defined $params->{enrich} || $params->{enrich}) ? 1 : 0;
        my $cache_key = build_cache_key('info', $symbol, $method, $enrich ? 'e' : '');

        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $info = _fetch_info_data($symbol, $method, $enrich);
        my $response = json_response('success', $info);
        FQCache::set($cache_key, $response);
        return $response;
    }

    # 4. Currency Conversion - core logic shared by REST and MCP
    sub _fetch_currency_data {
        my ($from, $to) = @_;

        # Strategy 1: AlphaVantage (if key available)
        if ($ALPHAVANTAGE_API_KEY) {
            my @pairs = ("$from$to");
            my %quotes = $quoter->fetch('alphavantage', @pairs);

            my $rate;
            foreach my $k (keys %quotes) {
                my $v = $quotes{$k};
                if (ref($v) eq 'HASH') {
                    $rate = $v->{close} || $v->{last} || $v->{rate};
                } elsif (!ref($v) && $v =~ /^-?[\d.]+$/) {
                    $rate = $v;
                }
                last if $rate;
            }

            return { from => $from, to => $to, rate => $rate + 0 }
                if $rate && $rate =~ /^-?[\d.]+$/;
        }

        # Strategy 2: Yahoo
        {
            my @pairs = ("$from$to");
            my %quotes = $quoter->fetch('yahooJSON', @pairs);

            my $rate;
            foreach my $k (keys %quotes) {
                my $v = $quotes{$k};
                if (ref($v) eq 'HASH' && $v->{success}) {
                    $rate = $v->{close} || $v->{last};
                    last if $rate;
                } elsif (!ref($v) && $v =~ /^-?[\d.]+$/) {
                    $rate = $v;
                    last if $rate;
                }
            }

            return { from => $from, to => $to, rate => $rate + 0 }
                if $rate && $rate =~ /^-?[\d.]+$/;
        }

        # Strategy 3: Currencies module
        {
            my @pairs = ("$from$to");
            my %quotes = $quoter->fetch('Currencies', @pairs);
            my $key = "$from$to";
            my $v = $quotes{$key};
            my $rate;
            if (ref($v) eq 'HASH') {
                $rate = $v->{last} || $v->{rate};
            } elsif (!ref($v) && $v =~ /^-?[\d.]+$/) {
                $rate = $v;
            }

            return { from => $from, to => $to, rate => $rate + 0 }
                if $rate && $rate =~ /^-?[\d.]+$/;
        }

        return undef;  # All strategies failed
    }

    sub handle_currency {
        my ($from, $to, $params) = @_;

        my $cache_key = build_cache_key('currency', $from, $to);
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $rate_data = _fetch_currency_data($from, $to);

        if ($rate_data) {
            my $response = json_response('success', $rate_data);
            FQCache::set($cache_key, $response);
            return $response;
        }

        return error_response(400, "Cannot convert $from to $to",
            "Exchange rate not available. Try setting ALPHAVANTAGE_API_KEY.");
    }

    # 5. Direct fetch with method
    sub handle_fetch {
        my ($method, $symbols, $params) = @_;

        $method = _normalize_method($method);
        my %valid_methods = map { $_ => 1 } @Finance::Quote::MODULES;

        unless ($valid_methods{$method}) {
            return error_response(400, "Unknown method: $method",
                "Use /api/v1/methods to see available methods");
        }

        my $enrich = (!defined $params->{enrich} || $params->{enrich}) ? 1 : 0;
        my $cache_key = build_cache_key('fetch', $method, $symbols, $enrich ? 'e' : '');
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $result = _fetch_quotes_data($symbols, $method, '', $enrich);
        my $response = json_response('success', $result);
        FQCache::set($cache_key, $response);
        return $response;
    }

    # ============================================
    # Quote History Handlers
    # ============================================

    sub handle_history {
        my ($symbol, $params) = @_;
        my $history = FQDB::get_history(
            symbol => $symbol,
            from   => $params->{from},
            to     => $params->{to},
            limit  => $params->{limit},
            method => $params->{method},
        );
        return json_response('success', {
            symbol  => $symbol,
            records => $history,
            count   => scalar(@$history),
        });
    }

    sub handle_history_overview {
        my ($params) = @_;
        my $symbols = FQDB::get_history_symbols();
        my $stats   = FQDB::history_stats();
        return json_response('success', {
            symbols => $symbols,
            stats   => $stats,
        });
    }

    # ============================================
    # Stock Chart Card Handler
    # ============================================

    sub handle_chart {
        my ($symbol, $params) = @_;
        my $size     = $params->{size} || 'medium';
        my $method   = _normalize_method($params->{method} || 'YahooJSON');
        my $currency = $params->{currency} || '';
        my $days     = $params->{days} || 90;
        my $format   = $params->{format} || 'svg';

        # Validate size
        my %valid_sizes = map { $_ => 1 } qw(small medium large);
        $size = 'medium' unless $valid_sizes{$size};

        # Validate format
        my %valid_formats = map { $_ => 1 } qw(svg json html);
        $format = 'svg' unless $valid_formats{$format};

        # Fetch live quote data (enrich=0: chart does its own DB lookup below)
        my $info = {};
        eval {
            my $cache_key = build_cache_key('info', $symbol, $method);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $parsed = JSON::XS::decode_json($cached->[2][0]);
                $info = $parsed->{data} // {};
            } else {
                $info = _fetch_info_data($symbol, $method, 0);
                my $response = json_response('success', $info);
                FQCache::set($cache_key, $response);
            }
        };

        # Fetch history data
        my $history = FQDB::get_history(
            symbol => $symbol,
            limit  => $days,
        );
        # History comes in DESC order, reverse for chart (oldest first)
        $history = [ reverse @$history ] if $history && @$history;

        # DB enrichment
        my $db_info = {};
        eval {
            $db_info = FQDB::lookup_symbol($symbol) // {};
        };

        # Determine price/change from info or latest history
        my $price      = $info->{close} // $info->{last};
        my $change     = $info->{change};
        my $pct_change = $info->{pct_change};
        my $name       = $info->{name} // $db_info->{name} // '';
        my $exchange   = $info->{exchange} // $db_info->{exchange} // '';
        my $cur        = $info->{currency} // $currency || 'USD';

        # If no live data, try to get from latest history
        if (!defined $price && $history && @$history) {
            my $latest = $history->[-1];
            $price      = $latest->{close} // $latest->{last};
            $name     //= $latest->{name} // '';
            $exchange //= $latest->{exchange} // '';
            $cur      //= $latest->{currency} // 'USD';
        }

        # Generate SVG
        my $svg = FQChart::generate_card(
            size       => $size,
            symbol     => uc($symbol),
            name       => $name,
            price      => $price,
            change     => $change,
            pct_change => $pct_change,
            currency   => $cur,
            exchange   => $exchange,
            history    => $history // [],
            info       => $info,
            db_info    => $db_info,
        );

        # Return in requested format
        if ($format eq 'json') {
            require MIME::Base64;
            my $b64 = MIME::Base64::encode_base64($svg, '');
            return json_response('success', {
                symbol  => uc($symbol),
                size    => $size,
                format  => 'svg+base64',
                image   => $b64,
                data_uri => "data:image/svg+xml;base64,$b64",
                width   => FQChart::available_sizes()->{$size}{width},
                height  => FQChart::available_sizes()->{$size}{height},
            });
        }

        if ($format eq 'html') {
            my $dim = FQChart::available_sizes()->{$size};
            my $html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\">" .
                "<title>$symbol Stock Card</title>" .
                "<style>body{margin:0;display:flex;justify-content:center;align-items:center;min-height:100vh;background:#0f0f1a;}</style>" .
                "</head><body>$svg</body></html>";
            return [ 200, [ 'Content-Type' => 'text/html; charset=utf-8', 'Access-Control-Allow-Origin' => '*' ], [ $html ] ];
        }

        # Default: raw SVG
        return [ 200, [
            'Content-Type' => 'image/svg+xml',
            'Access-Control-Allow-Origin' => '*',
            'Cache-Control' => 'public, max-age=300',
        ], [ $svg ] ];
    }

    # ============================================
    # MCP Protocol Handler - delegates to FQMCP module
    # ============================================

    sub handle_mcp {
        my ($body) = @_;
        return FQMCP::handle($body);
    }
}

# ============================================
# PSGI Entry Point - delegates to FQRouter
# ============================================

sub {
    my $env = shift;
    my $params = FQRouter::parse_query_string($env->{QUERY_STRING} // '');
    return FQRouter::dispatch($env, $params);
};
