#!/usr/bin/perl
# FinanceQuote API - PSGI Entry Point
# Wraps Finance::Quote Perl module as a REST API

use strict;
use warnings;
use utf8;
use JSON::XS qw(encode_json decode_json);

use lib 'lib';
use FQCache;
use FQDB;
use FQUtils;

use Plack::Builder;
use Finance::Quote;

# ============================================
# API Application
# ====================================

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

    # Normalize method names (handle case-insensitive input)
    sub _normalize_method {
        my ($method) = @_;
        my @methods = @Finance::Quote::MODULES;
        my %method_map;
        $method_map{lc($_)} = $_ for @methods;
        return $method_map{lc($method)} // $method;
    }

    # Register API routes for OpenAPI spec generation
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

    # Read cache configuration from environment
    my $FQ_CACHE_TTL = $ENV{'FQ_CACHE_TTL'} // 900;
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
    
    # Set currency BEFORE creating the quoter object
    if ($FQ_CURRENCY) {
        $ENV{'FQ_CURRENCY'} = $FQ_CURRENCY;
    }
    
    my $quoter = Finance::Quote->new(@quoter_args);

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
        my $method = $params->{method} || 'YahooJSON';
        $method = _normalize_method($method);
        my $currency = $params->{currency} || '';
        my $cache_key = build_cache_key('quote', $symbols, $method, $currency);
        
        # Check cache
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;
        
        my @syms = split(/,/, $symbols);
        
        # Set currency if specified
        $quoter->{currency} = $currency if $currency;
        
        # Fetch quotes
        my %quotes = $quoter->fetch($method, @syms);
        
        # Process and normalize results
        my $result = process_quote_results(\%quotes, \@syms);
        
        my $response = json_response('success', $result);
        FQCache::set($cache_key, $response);
        return $response;
    }

# 3b. Symbol Info (metadata)
    sub handle_info {
        my ($symbol, $params) = @_;
        
        # Build cache key
        my $method = $params->{method} || 'YahooJSON';
        $method = _normalize_method($method);
        my $cache_key = build_cache_key('info', $symbol, $method);
        
        # Check cache
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;
        
        # Fetch quote - we'll use the stock method to get metadata
        my %quotes = $quoter->fetch($method, $symbol);
        
        # Find the data for this symbol
        my $info;
        foreach my $key (keys %quotes) {
            my ($s, $attr) = split(/$;/, $key, 2);
            next unless $s eq $symbol;
            
            # Only include metadata fields (not price data)
            if ($attr =~ /^(name|exchange|cap|year_high|year_low|div|yield|eps|pe|volume|avg_vol|day_range|year_range|currency|pct_change|open|close|high|low|date|time|errormsg|success)$/) {
                $info->{$attr} = $quotes{$key};
            }
        }
        
        # Add symbol explicitly
        $info->{symbol} = $symbol;
        
        # If no data, mark as failed
        unless (keys %$info > 1) {
            $info = {
                symbol => $symbol,
                success => 0,
                errormsg => 'No data returned for symbol',
            };
        }
        
        my $response = json_response('success', $info);
        FQCache::set($cache_key, $response);
        return $response;
    }

# 4. Currency Conversion
    sub handle_currency {
        my ($from, $to, $params) = @_;
        
        # Build cache key
        my $cache_key = build_cache_key('currency', $from, $to);
        
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
        my %quotes = $quoter->fetch('yahooJSON', @pairs);
        
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
        
        # Validate and normalize method
        $method = _normalize_method($method);
        my @methods = @Finance::Quote::MODULES;
        my %method_map;
        @method_map{@methods} = ();
        
        unless (exists $method_map{$method}) {
            return error_response(400, "Unknown method: $method", "Use /api/v1/methods to see available methods");
        }
        
        # Build cache key
        my $cache_key = build_cache_key('fetch', $method, $symbols);
        
        # Check cache
        my $cached = FQCache::get($cache_key);
        return $cached if $cached;
        
        my @syms = split(/,/, $symbols);
        my %quotes = $quoter->fetch($method, @syms);
        
        # Process results
        my $result = process_quote_results(\%quotes, \@syms);
        
        my $response = json_response('success', $result);
        FQCache::set($cache_key, $response);
        return $response;
    }

    # ============================================
    # MCP Protocol Handler (Model Context Protocol)
    # ============================================
    
    sub handle_mcp {
        my ($body) = @_;
        
        # Parse JSON-RPC 2.0 request
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
        
        # Handle MCP methods
        if ($method eq 'initialize') {
            return jsonrpc_response($id, {
                protocolVersion => '2024-11-05',
                capabilities => {
                    tools => {},
                },
                serverInfo => {
                    name => 'FinanceQuote',
                    version => '1.69',
                },
            });
        }
        
        if ($method eq 'tools/list') {
            return jsonrpc_response($id, {
                tools => [
                    {
                        name => 'get_quote',
                        description => 'Fetch stock, ETF, or other financial quotes from various sources',
                        inputSchema => {
                            type => 'object',
                            properties => {
                                symbols => {
                                    type => 'string',
                                    description => 'Comma-separated list of symbols (e.g., AAPL,MSFT,GOOGL)',
                                },
                                method => {
                                    type => 'string',
                                    description => 'Quote method to use (default: yahooJSON)',
                                },
                                currency => {
                                    type => 'string',
                                    description => 'Desired currency code (e.g., USD, EUR)',
                                },
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
                                from => {
                                    type => 'string',
                                    description => 'Source currency code (e.g., USD)',
                                },
                                to => {
                                    type => 'string',
                                    description => 'Target currency code (e.g., EUR)',
                                },
                            },
                            required => ['from', 'to'],
                        },
                    },
                    {
                        name => 'list_methods',
                        description => 'List all available quote fetch methods',
                        inputSchema => {
                            type => 'object',
                            properties => {},
                        },
                    },
                    {
                        name => 'get_symbol_info',
                        description => 'Get detailed metadata information about a stock symbol (name, exchange, market cap, P/E ratio, dividend, etc.)',
                        inputSchema => {
                            type => 'object',
                            properties => {
                                symbol => {
                                    type => 'string',
                                    description => 'Stock symbol (e.g., AAPL, MSFT)',
                                },
                                method => {
                                    type => 'string',
                                    description => 'Quote method to use (default: yahooJSON)',
                                },
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
                                query => {
                                    type => 'string',
                                    description => 'Search query (name, symbol, or ISIN)',
                                },
                                type => {
                                    type => 'string',
                                    description => 'Asset type (equities, etfs, funds, indices, currencies, cryptos, moneymarkets)',
                                },
                                limit => {
                                    type => 'integer',
                                    description => 'Max results (default 20)',
                                },
                                primary => {
                                    type => 'boolean',
                                    description => 'Filter to primary exchanges only (default false)',
                                },
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
                                symbol => {
                                    type => 'string',
                                    description => 'Stock symbol (e.g., AAPL, MSFT)',
                                },
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
                                type => {
                                    type => 'string',
                                    description => 'Asset type (equities, etfs, funds, indices, currencies, cryptos, moneymarkets)',
                                },
                                sector => {
                                    type => 'string',
                                    description => 'Filter by sector (e.g., Technology, Healthcare)',
                                },
                                country => {
                                    type => 'string',
                                    description => 'Filter by country (e.g., United States, China)',
                                },
                                exchange => {
                                    type => 'string',
                                    description => 'Filter by exchange (e.g., NMS, LSE, HKG)',
                                },
                                market_cap => {
                                    type => 'string',
                                    description => 'Filter by market cap (Large Cap, Mid Cap, Small Cap, etc.)',
                                },
                                limit => {
                                    type => 'integer',
                                    description => 'Max results (default 100)',
                                },
                            },
                            required => ['type'],
                        },
                    },
                    {
                        name => 'get_db_stats',
                        description => 'Get database statistics (row counts per asset type)',
                        inputSchema => {
                            type => 'object',
                            properties => {},
                        },
                    },
                ],
            });
        }
        
        if ($method eq 'tools/call') {
            my $tool_name = $params->{name};
            my $tool_args = $params->{arguments} // {};
            
            if ($tool_name eq 'get_quote') {
                my $symbols = $tool_args->{symbols} // '';
                my $method = $tool_args->{method} // 'yahooJSON';
                my $currency = $tool_args->{currency} // '';
                
                # Build cache key
                my $cache_key = "mcp:quote:${symbols}:${method}:${currency}";
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    # Extract data from cached response and wrap in MCP format
                    my $data = _extract_mcp_data($cached);
                    return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($data) }] });
                }
                
                # Fetch quote
                my @syms = split(/,/, $symbols);
                $quoter->{currency} = $currency if $currency;
                my %quotes = $quoter->fetch($method, @syms);
                
                my %result;
                foreach my $sym (@syms) {
                    foreach my $key (keys %quotes) {
                        my ($s, $attr) = split(/$;/, $key, 2);
                        next unless $s eq $sym;
                        $result{$sym}{$attr} = $quotes{$key};
                    }
                    unless ($result{$sym}) {
                        $result{$sym} = { symbol => $sym, success => 0, errormsg => 'No data returned' };
                    }
                }
                
                my $response_data = { symbols => \%result };
                FQCache::set($cache_key, $response_data);
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($response_data) }] });
            }
            
            if ($tool_name eq 'get_currency') {
                my $from = $tool_args->{from} // '';
                my $to = $tool_args->{to} // '';
                
                my $cache_key = "currency:${from}:${to}";
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    # Cached response is [status_code, headers, body_array]
                    my $body = $cached->[2][0];
                    my $parsed = decode_json($body);
                    my $rate_data = $parsed->{data};
                    return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($rate_data) }] });
                }
                
                # Call handle_currency directly
                my $response = handle_currency($from, $to, {});
                
                # Cache the response for next time
                if ($response->[0] == 200) {
                    FQCache::set($cache_key, $response);
                    my $body = $response->[2][0];
                    my $parsed = decode_json($body);
                    my $rate_data = $parsed->{data};
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
                
                # Build cache key
                my $cache_key = "info:${symbol}:${method}";
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    my $body = $cached->[2][0];
                    my $parsed = decode_json($body);
                    my $info_data = $parsed->{data};
                    return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($info_data) }] });
                }
                
                # Fetch info
                my $response = handle_info($symbol, { method => $method });
                
                # Cache the response
                if ($response->[0] == 200) {
                    FQCache::set($cache_key, $response);
                    my $body = $response->[2][0];
                    my $parsed = decode_json($body);
                    my $info_data = $parsed->{data};
                    return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($info_data) }] });
                }
                
                return jsonrpc_error($id, -3201, "Symbol info failed", "Cannot get info for $symbol");
            }
            
            # Database tools
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
                return jsonrpc_error($id, -3202, "Symbol not found", "No data found for $symbol");
            }
            
            if ($tool_name eq 'filter_assets') {
                my $type = $tool_args->{type} // 'equities';
                my $sector = $tool_args->{sector};
                my $country = $tool_args->{country};
                my $exchange = $tool_args->{exchange};
                my $market_cap = $tool_args->{market_cap};
                my $limit = $tool_args->{limit} // 100;
                
                my $results = FQDB::filter(
                    type => $type,
                    sector => $sector,
                    country => $country,
                    exchange => $exchange,
                    market_cap => $market_cap,
                    limit => $limit,
                );
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
            }
            
            if ($tool_name eq 'get_db_stats') {
                my $stats = FQDB::stats();
                return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($stats) }] });
            }
            
            return jsonrpc_error($id, -32601, "Method not found", "Unknown tool: $tool_name");
        }
        
        return jsonrpc_error($id, -32601, "Method not found", "Unknown method: $method");
    }
    
    sub _extract_mcp_data {
        my ($cached) = @_;
        # Handle both array ref (cached response) and hash
        if (ref($cached) eq 'ARRAY') {
            return $cached->[0][3][0];  # This is simplistic - assumes cached response format
        }
        return $cached;
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
        $params{FQAPI::url_decode($k)} = FQAPI::url_decode($v) if $k;
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
    
    # Route: /api/v1/info/:symbol
    if ($path =~ m{^/api/v1/info/([^/]+)$}) {
        return FQAPI::handle_info($1, \%params);
    }
    
    # Route: /api/v1/currency/:from/:to
    if ($path =~ m{^/api/v1/currency/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_currency($1, $2, \%params);
    }
    
    # Route: /api/v1/fetch/:method/:symbols
    if ($path =~ m{^/api/v1/fetch/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_fetch($1, $2, \%params);
    }
    
    # ===== SQLite Database Routes =====
    
    # Route: /api/v1/db/stats - Database statistics
    if ($path eq '/api/v1/db/stats') {
        my $stats = FQDB::stats();
        return FQAPI::json_response('success', $stats);
    }
    
    # Route: /api/v1/db/assets - List available asset types
    if ($path eq '/api/v1/db/assets') {
        my $types = FQDB::asset_types();
        return FQAPI::json_response('success', { types => $types });
    }
    
    # Route: /api/v1/db/options/:type - Get filter options for a type
    if ($path =~ m{^/api/v1/db/options/([^/]+)$}) {
        my $type = $1;
        my $options = FQDB::get_filter_options($type);
        return FQAPI::json_response('success', $options);
    }
    
    # Route: /api/v1/search?q=...&type=...&limit=... - Search by name or symbol
    if ($path eq '/api/v1/search') {
        my $query = $params{q} // '';
        my $type = $params{type} // '';
        my $limit = $params{limit} // 20;
        my $primary_only = $params{primary} // 0;
        
        unless ($query) {
            return FQAPI::error_response(400, "Missing query", "Provide a search query with ?q=...");
        }
        
        my $results = FQDB::search($query, $type, $limit, { primary_only => $primary_only });
        return FQAPI::json_response('success', { results => $results, count => scalar(@$results) });
    }
    
    # Route: /api/v1/lookup/:symbol - Lookup exact symbol in database
    if ($path =~ m{^/api/v1/lookup/([^/]+)$}) {
        my $symbol = $1;
        my $result = FQDB::lookup_symbol($symbol);
        
        if ($result) {
            return FQAPI::json_response('success', $result);
        } else {
            return FQAPI::error_response(404, "Symbol not found", "No data found for symbol $symbol");
        }
    }
    
    # Route: /api/v1/filter - Filter assets by criteria
    if ($path eq '/api/v1/filter') {
        my $type = $params{type} // 'equities';
        my $sector = $params{sector};
        my $country = $params{country};
        my $exchange = $params{exchange};
        my $market_cap = $params{market_cap};
        my $industry = $params{industry};
        my $limit = $params{limit} // 100;
        
        my @valid_types = qw(equities etfs funds indices currencies cryptos moneymarkets);
        my %valid;
        @valid{@valid_types} = ();
        unless ($valid{$type}) {
            return FQAPI::error_response(400, "Invalid type", "Valid types: " . join(", ", @valid_types));
        }
        
        my $results = FQDB::filter(
            type => $type,
            sector => $sector,
            country => $country,
            exchange => $exchange,
            market_cap => $market_cap,
            industry => $industry,
            limit => $limit,
        );
        
        return FQAPI::json_response('success', { results => $results, count => scalar(@$results) });
    }
    
    # MCP Protocol endpoint (JSON-RPC 2.0)
    if ($path eq '/mcp' || $path eq '/mcp/sse') {
        # Handle POST (Streamable HTTP)
        if ($method eq 'POST') {
            my $content_length = $env->{CONTENT_LENGTH} // 0;
            my $body = '';
            if ($content_length > 0) {
                $env->{'psgi.input'}->read($body, $content_length);
            }
            return FQAPI::handle_mcp($body);
        }
        
        # Handle GET for SSE fallback (backwards compatibility with older clients)
        if ($method eq 'GET') {
            # Send SSE priming event per MCP spec
            my $event_id = time();
            my $sse_data = "event: endpoint\nid: $event_id\ndata:\n\n";
            return [ 200, [ 
                'Content-Type' => 'text/event-stream',
                'Cache-Control' => 'no-cache',
                'Access-Control-Allow-Origin' => '*',
                'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
                'Access-Control-Allow-Headers' => 'Content-Type, MCP-Protocol-Version, MCP-Session-Id',
            ], [ $sse_data ] ];
        }
        
        # Return 405 for other methods
        return [ 405, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Method not allowed"}}' ] ];
    }
    
    # Serve static files (documentation)
    if ($path eq '/' || $path eq '/index.html' || $path eq '/docs' || $path eq '/docs/') {
        my $html = do { local $/; open my $fh, '<', '/app/public/index.html'; <$fh> };
        return [ 200, [ 'Content-Type' => 'text/html', 'Access-Control-Allow-Origin' => '*' ], [ $html ] ];
    }
    
    # Serve OpenAPI spec (auto-generated from registered routes)
    if ($path eq '/openapi.yaml' || $path eq '/openapi.json') {
        my $fq_version = Finance::Quote->VERSION // 'unknown';
        
        if ($path eq '/openapi.json') {
            my $spec = FQUtils::get_openapi_spec(
                version => '1.69',
                fq_version => $fq_version,
            );
            $spec->{servers}[0]{url} = $env->{'psgi.url_scheme'} . '://' . ($env->{HTTP_HOST} // $env->{SERVER_NAME} // 'localhost:3001');
            return [ 200, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ encode_json($spec) ] ];
        }
        
        # YAML - use static file with dynamic replacements
        open my $fh, '<', '/app/public/openapi.yaml' or return [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Cannot read file' ] ];
        my $yaml = do { local $/; <$fh> };
        close $fh;
        
        my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME} // 'localhost:3001';
        my $scheme = $env->{'psgi.url_scheme'} // 'http';
        my $server_url = "$scheme://$host";
        $yaml =~ s/\{SERVER_URL\}/$server_url/ge;
        $yaml =~ s/\{FQ_VERSION\}/$fq_version/ge;
        
        return [ 200, [ 'Content-Type' => 'text/yaml', 'Access-Control-Allow-Origin' => '*' ], [ $yaml ] ];
    }
    
    # Serve OpenAPI spec as JSON (auto-generated)
    if ($path eq '/api/v1/spec') {
        my $fq_version = Finance::Quote->VERSION // 'unknown';
        my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME} // 'localhost:3001';
        my $scheme = $env->{'psgi.url_scheme'} // 'http';
        my $spec = FQUtils::get_openapi_spec(
            version => '1.69',
            fq_version => $fq_version,
        );
        $spec->{servers}[0]{url} = "$scheme://$host";
        return [ 200, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ encode_json($spec) ] ];
    }
    
    # Serve Swagger UI (redirect to main index)
    if ($path eq '/swagger' || $path eq '/swagger/') {
        return [ 302, [ 'Location' => '/', 'Access-Control-Allow-Origin' => '*' ], [ 'Redirecting...' ] ];
    }
    
    # Serve Swagger UI static assets
    if ($path =~ m{^/swagger/(.+)$}) {
        my $filename = $1;
        my $file_path = "/app/public/swagger/$filename";
        return [ 404, [ 'Content-Type' => 'text/plain', 'Access-Control-Allow-Origin' => '*' ], [ 'Not Found' ] ] unless -e $file_path;
        
        my $content_type = 'text/plain';
        if ($filename =~ /\.js$/) { $content_type = 'application/javascript'; }
        elsif ($filename =~ /\.css$/) { $content_type = 'text/css'; }
        elsif ($filename =~ /\.png$/) { $content_type = 'image/png'; }
        elsif ($filename =~ /\.jpe?g$/) { $content_type = 'image/jpeg'; }
        elsif ($filename =~ /\.svg$/) { $content_type = 'image/svg+xml'; }
        elsif ($filename =~ /\.woff2$/) { $content_type = 'font/woff2'; }
        elsif ($filename =~ /\.woff$/) { $content_type = 'font/woff'; }
        
        open my $fh, '<', $file_path or return [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Cannot read file' ] ];
        my $content = do { local $/; <$fh> };
        close $fh;
        return [ 200, [ 'Content-Type' => $content_type, 'Access-Control-Allow-Origin' => '*' ], [ $content ] ];
    }
    
    # Serve static images from public folder
    if ($path =~ m{^/([^/]+\.(?:jpg|jpeg|png|gif|svg)$)}) {
        my $file_path = "/app/public/$path";
        return [ 404, [ 'Content-Type' => 'text/plain', 'Access-Control-Allow-Origin' => '*' ], [ 'Not Found' ] ] unless -e $file_path;
        
        my $content_type = 'text/plain';
        if ($path =~ /\.jpe?g$/) { $content_type = 'image/jpeg'; }
        elsif ($path =~ /\.png$/) { $content_type = 'image/png'; }
        elsif ($path =~ /\.gif$/) { $content_type = 'image/gif'; }
        elsif ($path =~ /\.svg$/) { $content_type = 'image/svg+xml'; }
        
        open my $fh, '<', $file_path or return [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Cannot read file' ] ];
        my $content = do { local $/; <$fh> };
        close $fh;
        return [ 200, [ 'Content-Type' => $content_type, 'Access-Control-Allow-Origin' => '*' ], [ $content ] ];
    }
    
    # Default: 404 Not Found
    return FQAPI::error_response(404, "Not Found", "Path $path not found");
};