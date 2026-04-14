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
        description => 'Model Context Protocol JSON-RPC 2.0 endpoint. Supports: initialize, tools/list, tools/call, resources/list, resources/read, notifications/initialized. 14 tools available including composite analysis and portfolio tools.',
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
                capabilities    => {
                    tools     => {},
                    resources => {},
                },
                serverInfo      => {
                    name    => 'FinanceQuote',
                    version => $FQUtils::VERSION,
                },
            });
        }

        # --- notifications/initialized (client acknowledgment, no response needed) ---
        if ($method eq 'notifications/initialized') {
            # MCP spec: notifications don't get responses, but we return empty 200
            # to satisfy HTTP transport expectations
            return [ 200, [ 'Content-Type' => 'application/json', FQUtils::standard_headers() ], [''] ];
        }

        # --- tools/list ---
        if ($method eq 'tools/list') {
            return jsonrpc_response($id, { tools => _mcp_tool_definitions() });
        }

        # --- tools/call ---
        if ($method eq 'tools/call') {
            return _handle_mcp_tool_call($id, $params);
        }

        # --- resources/list ---
        if ($method eq 'resources/list') {
            return jsonrpc_response($id, { resources => _mcp_resource_definitions() });
        }

        # --- resources/read ---
        if ($method eq 'resources/read') {
            return _handle_mcp_resource_read($id, $params);
        }

        return jsonrpc_error($id, -32601, "Method not found",
            "Unknown method: $method. Supported: initialize, tools/list, tools/call, resources/list, resources/read");
    }

    sub _handle_mcp_tool_call {
        my ($id, $params) = @_;
        my $tool_name = $params->{name};
        my $tool_args = $params->{arguments} // {};

        # --- Composite tools ---

        if ($tool_name eq 'analyze_symbol') {
            my $query = $tool_args->{symbol} // '';
            my $method = $tool_args->{method} // 'yahooJSON';
            my $currency = $tool_args->{currency} // '';

            return jsonrpc_error($id, -32602, "Invalid params", "symbol is required")
                unless $query;

            my $analysis = {};

            # Step 1: DB lookup (exact match first)
            my $db_info = FQDB::lookup_symbol($query);
            if ($db_info) {
                $analysis->{database} = $db_info;
            } else {
                # Try search
                my $results = FQDB::search($query, '', 5, { primary_only => 1 });
                if ($results && @$results) {
                    $analysis->{database} = $results->[0];
                    $analysis->{search_matches} = scalar(@$results);
                    # Use the found symbol for live data
                    $query = $results->[0]{symbol} if $results->[0]{symbol};
                }
            }

            # Step 2: Live quote
            eval {
                my $cache_key = build_cache_key('quote', $query, $method, $currency);
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    my $parsed = JSON::XS::decode_json($cached->[2][0]);
                    $analysis->{quote} = $parsed->{data};
                } else {
                    my $result = _fetch_quotes_data($query, $method, $currency);
                    my $response = json_response('success', $result);
                    FQCache::set($cache_key, $response);
                    $analysis->{quote} = $result;
                }
            };

            # Step 3: Detailed info
            eval {
                my $cache_key = build_cache_key('info', $query, $method);
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    my $parsed = JSON::XS::decode_json($cached->[2][0]);
                    $analysis->{info} = $parsed->{data};
                } else {
                    my $info = _fetch_info_data($query, $method);
                    my $response = json_response('success', $info);
                    FQCache::set($cache_key, $response);
                    $analysis->{info} = $info;
                }
            };

            $analysis->{symbol} = $query;
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($analysis) }] });
        }

        if ($tool_name eq 'get_portfolio') {
            my $symbols_str = $tool_args->{symbols} // '';
            my $method = $tool_args->{method} // 'yahooJSON';
            my $currency = $tool_args->{currency} // '';

            return jsonrpc_error($id, -32602, "Invalid params", "symbols is required. Provide comma-separated symbols like AAPL,MSFT,GOOGL")
                unless $symbols_str;

            my @syms = split(/,/, $symbols_str);
            my %portfolio;

            foreach my $sym (@syms) {
                $sym =~ s/^\s+|\s+$//g;
                next unless $sym;

                my $cache_key = build_cache_key('quote', $sym, $method, $currency);
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    my $parsed = JSON::XS::decode_json($cached->[2][0]);
                    $portfolio{$sym} = $parsed->{data}{$sym} // $parsed->{data};
                } else {
                    eval {
                        my $result = _fetch_quotes_data($sym, $method, $currency);
                        my $response = json_response('success', $result);
                        FQCache::set($cache_key, $response);
                        $portfolio{$sym} = $result->{$sym} // $result;
                    };
                    if ($@) {
                        $portfolio{$sym} = { error => "Failed to fetch: $@" };
                    }
                }
            }

            my $output = {
                portfolio => \%portfolio,
                count     => scalar(keys %portfolio),
                method    => $method,
                currency  => $currency || 'default',
            };
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($output) }] });
        }

        if ($tool_name eq 'compare_symbols') {
            my $symbols_str = $tool_args->{symbols} // '';
            my $method = $tool_args->{method} // 'yahooJSON';

            return jsonrpc_error($id, -32602, "Invalid params", "symbols is required. Provide 2+ comma-separated symbols like AAPL,MSFT")
                unless $symbols_str;

            my @syms = split(/,/, $symbols_str);
            return jsonrpc_error($id, -32602, "Invalid params", "Provide at least 2 symbols to compare")
                unless @syms >= 2;

            my @comparison;
            foreach my $sym (@syms) {
                $sym =~ s/^\s+|\s+$//g;
                next unless $sym;

                my $entry = { symbol => $sym };

                # Fetch info (has PE, yield, cap, etc.)
                eval {
                    my $cache_key = build_cache_key('info', $sym, $method);
                    my $cached = FQCache::get($cache_key);
                    if ($cached) {
                        my $parsed = JSON::XS::decode_json($cached->[2][0]);
                        $entry = { %$entry, %{$parsed->{data}} };
                    } else {
                        my $info = _fetch_info_data($sym, $method);
                        my $response = json_response('success', $info);
                        FQCache::set($cache_key, $response);
                        $entry = { %$entry, %$info };
                    }
                };

                # DB enrichment
                eval {
                    my $db_info = FQDB::lookup_symbol($sym);
                    if ($db_info) {
                        $entry->{sector} //= $db_info->{sector};
                        $entry->{country} //= $db_info->{country};
                        $entry->{market_cap} //= $db_info->{market_cap};
                        $entry->{industry} //= $db_info->{industry};
                    }
                };

                push @comparison, $entry;
            }

            my $output = {
                comparison => \@comparison,
                fields     => [qw(symbol name exchange close high low pe yield cap volume currency)],
            };
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($output) }] });
        }

        if ($tool_name eq 'convert_amount') {
            my $amount = $tool_args->{amount};
            my $from = $tool_args->{from} // '';
            my $to = $tool_args->{to} // '';

            return jsonrpc_error($id, -32602, "Invalid params", "amount, from, and to are all required. Example: amount=100, from=USD, to=EUR")
                unless defined($amount) && $from && $to;

            return jsonrpc_error($id, -32602, "Invalid params", "amount must be a positive number")
                unless $amount =~ /^[\d.]+$/ && $amount > 0;

            my $cache_key = build_cache_key('currency', $from, $to);
            my $cached = FQCache::get($cache_key);
            my $rate_data;

            if ($cached) {
                my $parsed = JSON::XS::decode_json($cached->[2][0]);
                $rate_data = $parsed->{data};
            } else {
                $rate_data = _fetch_currency_data($from, $to);
                if ($rate_data) {
                    my $response = json_response('success', $rate_data);
                    FQCache::set($cache_key, $response);
                }
            }

            if ($rate_data && $rate_data->{rate}) {
                my $converted = sprintf("%.4f", $amount * $rate_data->{rate});
                my $result = {
                    from             => $from,
                    to               => $to,
                    rate             => $rate_data->{rate},
                    original_amount  => $amount + 0,
                    converted_amount => $converted + 0,
                    display          => "$amount $from = $converted $to",
                };
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
            }
            return jsonrpc_error($id, -32001, "Currency conversion failed",
                "Cannot convert $from to $to. Verify both are valid ISO 4217 currency codes.");
        }

        # --- Original tools ---

        if ($tool_name eq 'get_quote') {
            my $symbols = $tool_args->{symbols} // '';
            my $method = $tool_args->{method} // 'yahooJSON';
            my $currency = $tool_args->{currency} // '';

            return jsonrpc_error($id, -32602, "Invalid params", "symbols is required. Provide comma-separated ticker symbols like AAPL,MSFT")
                unless $symbols;

            my $cache_key = build_cache_key('quote', $symbols, $method, $currency);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $body = $cached->[2][0];
                my $parsed = JSON::XS::decode_json($body);
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
            }

            my $result = _fetch_quotes_data($symbols, $method, $currency);
            my $response = json_response('success', $result);
            FQCache::set($cache_key, $response);
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
        }

        if ($tool_name eq 'get_currency') {
            my $from = $tool_args->{from} // '';
            my $to = $tool_args->{to} // '';

            return jsonrpc_error($id, -32602, "Invalid params", "from and to are required. Use ISO 4217 codes like USD, EUR, GBP")
                unless $from && $to;

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
            return jsonrpc_error($id, -32001, "Currency conversion failed",
                "Cannot convert $from to $to. Verify both are valid ISO 4217 currency codes. Try setting ALPHAVANTAGE_API_KEY for broader coverage.");
        }

        if ($tool_name eq 'list_methods') {
            my @methods = @Finance::Quote::MODULES;
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ methods => \@methods, count => scalar(@methods) }) }] });
        }

        if ($tool_name eq 'get_symbol_info') {
            my $symbol = $tool_args->{symbol} // '';
            my $method = $tool_args->{method} // 'yahooJSON';

            return jsonrpc_error($id, -32602, "Invalid params", "symbol is required. Provide a ticker symbol like AAPL or MSFT")
                unless $symbol;

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

            return jsonrpc_error($id, -32602, "Invalid params",
                "query is required. Search by company name (e.g., 'Apple'), ticker (e.g., 'AAPL'), or ISIN")
                unless $query;

            my $results = FQDB::search($query, $type, $limit, { primary_only => $primary });
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
        }

        if ($tool_name eq 'lookup_symbol') {
            my $symbol = $tool_args->{symbol} // '';

            return jsonrpc_error($id, -32602, "Invalid params", "symbol is required. Provide an exact ticker symbol like AAPL")
                unless $symbol;

            my $result = FQDB::lookup_symbol($symbol);
            if ($result) {
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
            }
            return jsonrpc_error($id, -32002, "Symbol not found",
                "No data found for '$symbol'. Try search_assets to find the correct ticker symbol.");
        }

        if ($tool_name eq 'filter_assets') {
            my $type = $tool_args->{type} // '';

            return jsonrpc_error($id, -32602, "Invalid params",
                "type is required. Valid types: equities, etfs, funds, indices, currencies, cryptos, moneymarkets")
                unless $type;

            my $results = FQDB::filter(
                type       => $type,
                sector     => $tool_args->{sector},
                country    => $tool_args->{country},
                exchange   => $tool_args->{exchange},
                market_cap => $tool_args->{market_cap},
                industry   => $tool_args->{industry},
                limit      => $tool_args->{limit} // 100,
            );
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
        }

        if ($tool_name eq 'get_filter_options') {
            my $type = $tool_args->{type} // 'equities';
            my $options = FQDB::get_filter_options($type);
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($options) }] });
        }

        if ($tool_name eq 'get_asset_types') {
            my $types = FQDB::asset_types();
            my $stats = FQDB::stats();
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ types => $types, stats => $stats }) }] });
        }

        if ($tool_name eq 'get_db_stats') {
            my $stats = FQDB::stats();
            return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($stats) }] });
        }

        return jsonrpc_error($id, -32601, "Tool not found",
            "Unknown tool: $tool_name. Use tools/list to see available tools.");
    }

    sub _mcp_tool_definitions {
        return [
            # --- Composite tools (recommended for most use cases) ---
            {
                name => 'analyze_symbol',
                description => 'All-in-one symbol analysis. Given a company name or ticker symbol, returns database metadata (sector, country, exchange, ISIN), live quote (price, change, volume), and detailed info (PE, yield, market cap) in a single call. START HERE if you need comprehensive data about a stock. Example: symbol="AAPL" or symbol="Apple". Returns: { database: {...}, quote: {...}, info: {...} }',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbol   => { type => 'string', description => 'Ticker symbol (e.g., AAPL) or company name (e.g., Apple). Names are auto-resolved to tickers.' },
                        method   => { type => 'string', description => 'Data source (default: yahooJSON). Use list_methods to see all available sources.' },
                        currency => { type => 'string', description => 'Convert prices to this currency (ISO 4217, e.g., EUR, GBP). Omit for native currency.' },
                    },
                    required => ['symbol'],
                },
            },
            {
                name => 'get_portfolio',
                description => 'Fetch live quotes for multiple symbols in one call. Ideal for portfolio tracking, watchlists, or batch price checks. Returns per-symbol quote data including last price, change, volume, and day range. Example: symbols="AAPL,MSFT,GOOGL,AMZN". Returns: { portfolio: { AAPL: {...}, MSFT: {...} }, count: N }',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbols  => { type => 'string', description => 'Comma-separated ticker symbols (e.g., AAPL,MSFT,GOOGL,AMZN,TSLA)' },
                        method   => { type => 'string', description => 'Data source (default: yahooJSON)' },
                        currency => { type => 'string', description => 'Convert all prices to this currency (ISO 4217). Omit for native currencies.' },
                    },
                    required => ['symbols'],
                },
            },
            {
                name => 'compare_symbols',
                description => 'Side-by-side comparison of 2 or more stocks. Returns price, PE ratio, dividend yield, market cap, sector, country, and volume for each symbol. Use this when comparing investment options. Example: symbols="AAPL,MSFT,GOOGL". Returns: { comparison: [{symbol, close, pe, yield, cap, ...}, ...] }',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbols => { type => 'string', description => 'Comma-separated symbols to compare (minimum 2, e.g., AAPL,MSFT)' },
                        method  => { type => 'string', description => 'Data source (default: yahooJSON)' },
                    },
                    required => ['symbols'],
                },
            },
            {
                name => 'convert_amount',
                description => 'Convert a monetary amount between currencies. Returns the exchange rate AND the converted amount. Example: amount=1000, from=USD, to=EUR. Returns: { rate: 0.92, original_amount: 1000, converted_amount: 920.00, display: "1000 USD = 920.00 EUR" }',
                inputSchema => {
                    type => 'object',
                    properties => {
                        amount => { type => 'number', description => 'Amount to convert (e.g., 1000)' },
                        from   => { type => 'string', description => 'Source currency ISO 4217 code (e.g., USD, GBP, JPY)' },
                        to     => { type => 'string', description => 'Target currency ISO 4217 code (e.g., EUR, CHF, CNY)' },
                    },
                    required => ['amount', 'from', 'to'],
                },
            },

            # --- Core data tools ---
            {
                name => 'get_quote',
                description => 'Fetch raw live quotes for one or more symbols. Returns per-symbol hash with fields: last, close, open, high, low, volume, change, p_change, currency, date, time, name, exchange, method, success. Use get_portfolio for multiple symbols or analyze_symbol for comprehensive data. Example: symbols="AAPL,MSFT"',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbols  => { type => 'string', description => 'Comma-separated ticker symbols (e.g., AAPL or AAPL,MSFT,GOOGL)' },
                        method   => { type => 'string', description => 'Data source. Common: yahooJSON (default, best coverage), AlphaVantage (needs API key). Use list_methods for all.' },
                        currency => { type => 'string', description => 'Convert prices to this currency (ISO 4217, e.g., EUR). Omit for native currency.' },
                    },
                    required => ['symbols'],
                },
            },
            {
                name => 'get_symbol_info',
                description => 'Get detailed metadata for a single stock symbol. Returns: symbol, name, exchange, currency, close, open, high, low, volume, pe, eps, div, yield, cap, year_high, year_low, day_range, year_range, pct_change. Use analyze_symbol instead if you also need database metadata.',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbol => { type => 'string', description => 'Single ticker symbol (e.g., AAPL, MSFT, 0700.HK)' },
                        method => { type => 'string', description => 'Data source (default: yahooJSON)' },
                    },
                    required => ['symbol'],
                },
            },
            {
                name => 'get_currency',
                description => 'Get the exchange rate between two currencies. Returns: { from, to, rate }. For converting an actual amount, use convert_amount instead. Example: from=USD, to=EUR returns { rate: 0.92 }',
                inputSchema => {
                    type => 'object',
                    properties => {
                        from => { type => 'string', description => 'Source currency ISO 4217 code (e.g., USD, EUR, GBP, JPY, CHF)' },
                        to   => { type => 'string', description => 'Target currency ISO 4217 code' },
                    },
                    required => ['from', 'to'],
                },
            },

            # --- Database discovery tools ---
            {
                name => 'search_assets',
                description => 'Search the financial database by company name, ticker symbol, or ISIN. Searches across all asset types (equities, ETFs, funds, indices, currencies, cryptos). Returns: { results: [{symbol, name, exchange, country, sector, market_cap, isin, type}], count }. Use primary=true to filter to major exchanges only. Example: query="Apple", type="equities"',
                inputSchema => {
                    type => 'object',
                    properties => {
                        query   => { type => 'string',  description => 'Search term: company name (e.g., "Apple"), ticker (e.g., "AAPL"), or ISIN (e.g., "US0378331005")' },
                        type    => { type => 'string',  description => 'Restrict to asset type: equities, etfs, funds, indices, currencies, cryptos, moneymarkets' },
                        limit   => { type => 'integer', description => 'Max results to return (default: 20, max recommended: 100)' },
                        primary => { type => 'boolean', description => 'If true, only return results from major exchanges (NYSE, NASDAQ, LSE, etc.)' },
                    },
                    required => ['query'],
                },
            },
            {
                name => 'lookup_symbol',
                description => 'Get exact database record for a ticker symbol. Returns all stored fields: symbol, name, exchange, country, sector, industry, market_cap, isin, currency, and more. Returns error if symbol not found - use search_assets to find the correct ticker first.',
                inputSchema => {
                    type => 'object',
                    properties => {
                        symbol => { type => 'string', description => 'Exact ticker symbol (e.g., AAPL, MSFT). Case-insensitive.' },
                    },
                    required => ['symbol'],
                },
            },
            {
                name => 'filter_assets',
                description => 'Filter assets by criteria. Useful for screening stocks by sector, country, exchange, or market cap. Returns: { results: [{symbol, name, exchange, country, sector, industry, market_cap}], count }. Use get_filter_options first to discover valid filter values. Example: type=equities, sector=Technology, country=United States',
                inputSchema => {
                    type => 'object',
                    properties => {
                        type       => { type => 'string',  description => 'Asset type (required): equities, etfs, funds, indices, currencies, cryptos, moneymarkets' },
                        sector     => { type => 'string',  description => 'Sector filter (e.g., Technology, Healthcare, Financial Services). Use get_filter_options to see valid values.' },
                        industry   => { type => 'string',  description => 'Industry filter (partial match, e.g., "Software", "Semiconductors")' },
                        country    => { type => 'string',  description => 'Country filter (e.g., United States, China, Germany)' },
                        exchange   => { type => 'string',  description => 'Exchange filter (e.g., NMS, NYQ, LSE, HKG)' },
                        market_cap => { type => 'string',  description => 'Market cap tier: Large Cap, Mid Cap, Small Cap, Mega Cap, Micro Cap, Nano Cap' },
                        limit      => { type => 'integer', description => 'Max results (default: 100)' },
                    },
                    required => ['type'],
                },
            },
            {
                name => 'get_filter_options',
                description => 'Get available filter values for a given asset type. Returns lists of valid sectors, countries, exchanges, and market_cap tiers. Call this BEFORE filter_assets to know what filter values are valid. Example: type=equities returns { sectors: ["Technology",...], countries: [...], exchanges: [...], market_caps: [...] }',
                inputSchema => {
                    type => 'object',
                    properties => {
                        type => { type => 'string', description => 'Asset type: equities, etfs, funds, indices, currencies, cryptos, moneymarkets (default: equities)' },
                    },
                },
            },
            {
                name => 'get_asset_types',
                description => 'List all available asset types in the database with descriptions and row counts. Returns: { types: [{name, description}], stats: {equities: N, etfs: N, ...} }. Call this first to understand what data is available.',
                inputSchema => { type => 'object', properties => {} },
            },

            # --- Utility tools ---
            {
                name => 'list_methods',
                description => 'List all available Finance::Quote data source methods. Most users should use "yahooJSON" (default, broadest coverage). Other methods may require API keys. Returns: { methods: [...], count: N }',
                inputSchema => { type => 'object', properties => {} },
            },
            {
                name => 'get_db_stats',
                description => 'Get database row counts per asset type. Returns: { equities: N, etfs: N, funds: N, indices: N, currencies: N, cryptos: N, moneymarkets: N, total: N }. Database is updated daily.',
                inputSchema => { type => 'object', properties => {} },
            },
        ];
    }

    # ============================================
    # MCP Resources
    # ============================================

    sub _mcp_resource_definitions {
        return [
            {
                uri         => 'financequote://methods',
                name        => 'Available Quote Methods',
                description => 'List of all Finance::Quote data source methods. Updated at server startup.',
                mimeType    => 'application/json',
            },
            {
                uri         => 'financequote://asset-types',
                name        => 'Asset Types',
                description => 'Available asset types in the database with descriptions and row counts.',
                mimeType    => 'application/json',
            },
            {
                uri         => 'financequote://server-info',
                name        => 'Server Information',
                description => 'API version, cache status, and supported capabilities.',
                mimeType    => 'application/json',
            },
        ];
    }

    sub _handle_mcp_resource_read {
        my ($id, $params) = @_;
        my $uri = $params->{uri} // '';

        if ($uri eq 'financequote://methods') {
            my @methods = @Finance::Quote::MODULES;
            my $content = encode_json({ methods => \@methods, count => scalar(@methods) });
            return jsonrpc_response($id, {
                contents => [{
                    uri      => $uri,
                    mimeType => 'application/json',
                    text     => $content,
                }],
            });
        }

        if ($uri eq 'financequote://asset-types') {
            my $types = FQDB::asset_types();
            my $stats = FQDB::stats();
            my $content = encode_json({ types => $types, stats => $stats });
            return jsonrpc_response($id, {
                contents => [{
                    uri      => $uri,
                    mimeType => 'application/json',
                    text     => $content,
                }],
            });
        }

        if ($uri eq 'financequote://server-info') {
            my $cache_stats = FQCache::stats();
            my $content = encode_json({
                name    => 'FinanceQuote API',
                version => $FQUtils::VERSION,
                cache   => $cache_stats,
                capabilities => [qw(quotes currency_conversion symbol_info asset_search portfolio_tracking)],
            });
            return jsonrpc_response($id, {
                contents => [{
                    uri      => $uri,
                    mimeType => 'application/json',
                    text     => $content,
                }],
            });
        }

        return jsonrpc_error($id, -32002, "Resource not found",
            "Unknown resource URI: $uri. Use resources/list to see available resources.");
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
