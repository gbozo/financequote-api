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
        description => 'Fetch stock quotes for given symbols',
        params => [
            { name => 'symbols', in => 'path', required => 1, type => 'string', description => 'Comma-separated symbols' },
            { name => 'method', in => 'query', type => 'string', description => 'Quote method (default: yahooJSON)' },
            { name => 'currency', in => 'query', type => 'string', description => 'Desired currency (e.g., EUR)' },
        ],
        responses => { '200' => { description => 'Quote data' } },
    });
    FQUtils::register_route('/api/v1/info/{symbol}', 'get', {
        summary => 'Get Symbol Info',
        description => 'Get detailed metadata about a stock symbol',
        params => [
            { name => 'symbol', in => 'path', required => 1, type => 'string', description => 'Stock symbol' },
            { name => 'method', in => 'query', type => 'string', description => 'Quote method' },
        ],
        responses => { '200' => { description => 'Symbol metadata' } },
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
        description => 'Fetch quotes using a specific method',
        params => [
            { name => 'method', in => 'path', required => 1, type => 'string', description => 'FQ method name' },
            { name => 'symbols', in => 'path', required => 1, type => 'string', description => 'Symbols' },
        ],
        responses => { '200' => { description => 'Quote data' } },
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
    FQUtils::register_route('/mcp', 'post', {
        summary => 'MCP Endpoint',
        description => 'Model Context Protocol JSON-RPC 2.0 endpoint',
        responses => { '200' => { description => 'JSON-RPC response' } },
    });
    FQUtils::register_route('/mcp', 'get', {
        summary => 'MCP SSE Endpoint',
        description => 'MCP Server-Sent Events fallback',
        responses => { '200' => { description => 'SSE stream' } },
    });
    FQUtils::register_route('/mcp/sse', 'get', {
        summary => 'MCP SSE Endpoint',
        description => 'MCP Server-Sent Events endpoint',
        responses => { '200' => { description => 'SSE stream' } },
    });

    # ============================================
    # Configuration
    # ============================================

    # Cache configuration
    my $FQ_CACHE_TTL = $ENV{'FQ_CACHE_TTL'} // 900;
    my $FQ_CACHE_ENABLED = $ENV{'FQ_CACHE_ENABLED'} // 1;
    my $FQ_CACHE_MAX = $ENV{'FQ_CACHE_MAX_ENTRIES'} // 10000;
    FQCache::configure($FQ_CACHE_TTL, $FQ_CACHE_ENABLED, $FQ_CACHE_MAX);

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

    # 3. Fetch Quotes - core logic shared by REST and MCP
    sub _fetch_quotes_data {
        my ($symbols_str, $method, $currency) = @_;
        $method = _normalize_method($method || 'YahooJSON');
        $currency //= '';

        my @syms = split(/,/, $symbols_str);
        $quoter->{currency} = $currency if $currency;
        my %quotes = $quoter->fetch($method, @syms);
        return process_quote_results(\%quotes, \@syms);
    }

    sub handle_quote {
        my ($symbols, $params) = @_;

        my $method = $params->{method} || 'YahooJSON';
        $method = _normalize_method($method);
        my $currency = $params->{currency} || '';
        my $cache_key = build_cache_key('quote', $symbols, $method, $currency);

        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $result = _fetch_quotes_data($symbols, $method, $currency);
        my $response = json_response('success', $result);
        FQCache::set($cache_key, $response);
        return $response;
    }

    # 3b. Symbol Info - core logic shared by REST and MCP
    sub _fetch_info_data {
        my ($symbol, $method) = @_;
        $method = _normalize_method($method || 'YahooJSON');

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
        return $info;
    }

    sub handle_info {
        my ($symbol, $params) = @_;

        my $method = $params->{method} || 'YahooJSON';
        $method = _normalize_method($method);
        my $cache_key = build_cache_key('info', $symbol, $method);

        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $info = _fetch_info_data($symbol, $method);
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

        my $cache_key = build_cache_key('fetch', $method, $symbols);
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;

        my $result = _fetch_quotes_data($symbols, $method, '');
        my $response = json_response('success', $result);
        FQCache::set($cache_key, $response);
        return $response;
    }

    # ============================================
    # MCP Protocol Handler (Model Context Protocol)
    # ============================================

    sub handle_mcp {
        my ($body) = @_;

        my $req;
        eval { $req = JSON::XS::decode_json($body); };
        if ($@ || !$req) {
            return json_error_response(-32700, "Parse error", "Invalid JSON");
        }

        my $jsonrpc = $req->{jsonrpc} // '';
        my $id = $req->{id};
        my $method = $req->{method};
        my $params = $req->{params} // {};

        unless ($jsonrpc eq '2.0') {
            return json_error_response(-32600, "Invalid Request", "jsonrpc must be '2.0'");
        }

        # --- initialize ---
        if ($method eq 'initialize') {
            return jsonrpc_response($id, {
                protocolVersion => '2024-11-05',
                capabilities    => { tools => {} },
                serverInfo      => {
                    name    => 'FinanceQuote',
                    version => $FQUtils::VERSION,
                },
            });
        }

        # --- tools/list ---
        if ($method eq 'tools/list') {
            return jsonrpc_response($id, { tools => _mcp_tool_definitions() });
        }

        # --- tools/call ---
        if ($method eq 'tools/call') {
            return _handle_mcp_tool_call($id, $params);
        }

        return jsonrpc_error($id, -32601, "Method not found", "Unknown method: $method");
    }

    sub _handle_mcp_tool_call {
        my ($id, $params) = @_;
        my $tool_name = $params->{name};
        my $tool_args = $params->{arguments} // {};

        if ($tool_name eq 'get_quote') {
            my $symbols = $tool_args->{symbols} // '';
            my $method = $tool_args->{method} // 'yahooJSON';
            my $currency = $tool_args->{currency} // '';

            my $cache_key = build_cache_key('quote', $symbols, $method, $currency);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                # Cached is a PSGI response: [status, headers, [body_json]]
                my $body = $cached->[2][0];
                my $parsed = JSON::XS::decode_json($body);
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
            }

            my $result = _fetch_quotes_data($symbols, $method, $currency);
            # Cache as PSGI response so REST and MCP share the same cache
            my $response = json_response('success', $result);
            FQCache::set($cache_key, $response);
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
        }

        if ($tool_name eq 'get_currency') {
            my $from = $tool_args->{from} // '';
            my $to = $tool_args->{to} // '';

            my $cache_key = build_cache_key('currency', $from, $to);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $body = $cached->[2][0];
                my $parsed = JSON::XS::decode_json($body);
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
            }

            my $rate_data = _fetch_currency_data($from, $to);
            if ($rate_data) {
                my $response = json_response('success', $rate_data);
                FQCache::set($cache_key, $response);
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($rate_data) }] });
            }
            return jsonrpc_error($id, -32001, "Currency conversion failed", "Cannot convert $from to $to");
        }

        if ($tool_name eq 'list_methods') {
            my @methods = @Finance::Quote::MODULES;
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ methods => \@methods }) }] });
        }

        if ($tool_name eq 'get_symbol_info') {
            my $symbol = $tool_args->{symbol} // '';
            my $method = $tool_args->{method} // 'yahooJSON';

            my $cache_key = build_cache_key('info', $symbol, $method);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $body = $cached->[2][0];
                my $parsed = JSON::XS::decode_json($body);
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
            }

            my $info = _fetch_info_data($symbol, $method);
            my $response = json_response('success', $info);
            FQCache::set($cache_key, $response);
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($info) }] });
        }

        if ($tool_name eq 'search_assets') {
            my $query = $tool_args->{query} // '';
            my $type = $tool_args->{type} // '';
            my $limit = $tool_args->{limit} // 20;
            my $primary = $tool_args->{primary} // 0;
            my $results = FQDB::search($query, $type, $limit, { primary_only => $primary });
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
        }

        if ($tool_name eq 'lookup_symbol') {
            my $symbol = $tool_args->{symbol} // '';
            my $result = FQDB::lookup_symbol($symbol);
            if ($result) {
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
            }
            return jsonrpc_error($id, -32002, "Symbol not found", "No data found for $symbol");
        }

        if ($tool_name eq 'filter_assets') {
            my $results = FQDB::filter(
                type       => $tool_args->{type} // 'equities',
                sector     => $tool_args->{sector},
                country    => $tool_args->{country},
                exchange   => $tool_args->{exchange},
                market_cap => $tool_args->{market_cap},
                limit      => $tool_args->{limit} // 100,
            );
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
        }

        if ($tool_name eq 'get_db_stats') {
            my $stats = FQDB::stats();
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($stats) }] });
        }

        return jsonrpc_error($id, -32601, "Method not found", "Unknown tool: $tool_name");
    }

    sub _mcp_tool_definitions {
        return [
            {
                name => 'get_quote',
                description => 'Fetch stock, ETF, or other financial quotes from various sources',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbols  => { type => 'string', description => 'Comma-separated list of symbols (e.g., AAPL,MSFT,GOOGL)' },
                        method   => { type => 'string', description => 'Quote method to use (default: yahooJSON)' },
                        currency => { type => 'string', description => 'Desired currency code (e.g., USD, EUR)' },
                    },
                    required => ['symbols'],
                },
            },
            {
                name => 'get_currency',
                description => 'Get currency exchange rate between two currencies',
                inputSchema => {
                    type => 'object',
                    properties => {
                        from => { type => 'string', description => 'Source currency code (e.g., USD)' },
                        to   => { type => 'string', description => 'Target currency code (e.g., EUR)' },
                    },
                    required => ['from', 'to'],
                },
            },
            {
                name => 'list_methods',
                description => 'List all available quote fetch methods',
                inputSchema => { type => 'object', properties => {} },
            },
            {
                name => 'get_symbol_info',
                description => 'Get detailed metadata information about a stock symbol (name, exchange, market cap, P/E ratio, dividend, etc.)',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbol => { type => 'string', description => 'Stock symbol (e.g., AAPL, MSFT)' },
                        method => { type => 'string', description => 'Quote method to use (default: yahooJSON)' },
                    },
                    required => ['symbol'],
                },
            },
            {
                name => 'search_assets',
                description => 'Search for financial assets by name, symbol, or ISIN. Use primary=true to filter primary listings only.',
                inputSchema => {
                    type => 'object',
                    properties => {
                        query   => { type => 'string',  description => 'Search query (name, symbol, or ISIN)' },
                        type    => { type => 'string',  description => 'Asset type (equities, etfs, funds, indices, currencies, cryptos, moneymarkets)' },
                        limit   => { type => 'integer', description => 'Max results (default 20)' },
                        primary => { type => 'boolean', description => 'Filter to primary exchanges only (default false)' },
                    },
                    required => ['query'],
                },
            },
            {
                name => 'lookup_symbol',
                description => 'Lookup exact symbol details from the database (name, exchange, country, sector, ISIN, etc.)',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbol => { type => 'string', description => 'Stock symbol (e.g., AAPL, MSFT)' },
                    },
                    required => ['symbol'],
                },
            },
            {
                name => 'filter_assets',
                description => 'Filter assets by criteria like sector, country, exchange, market cap',
                inputSchema => {
                    type => 'object',
                    properties => {
                        type       => { type => 'string',  description => 'Asset type (equities, etfs, funds, indices, currencies, cryptos, moneymarkets)' },
                        sector     => { type => 'string',  description => 'Filter by sector (e.g., Technology, Healthcare)' },
                        country    => { type => 'string',  description => 'Filter by country (e.g., United States, China)' },
                        exchange   => { type => 'string',  description => 'Filter by exchange (e.g., NMS, LSE, HKG)' },
                        market_cap => { type => 'string',  description => 'Filter by market cap (Large Cap, Mid Cap, Small Cap, etc.)' },
                        limit      => { type => 'integer', description => 'Max results (default 100)' },
                    },
                    required => ['type'],
                },
            },
            {
                name => 'get_db_stats',
                description => 'Get database statistics (row counts per asset type)',
                inputSchema => { type => 'object', properties => {} },
            },
        ];
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
