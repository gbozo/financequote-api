package FQMCP;

# MCP (Model Context Protocol) handler module.
# All JSON-RPC dispatch, tool definitions, resource definitions,
# and prompt definitions live here.
#
# Requires initialization via configure() with references to
# shared data-fetching functions from FQAPI.

use strict;
use warnings;
use JSON::XS qw(encode_json);

use FQUtils;
use FQCache;
use FQDB;

# ============================================
# Module state - set via configure()
# ============================================

my $fetch_quotes_fn;    # coderef: ($symbols_str, $method, $currency) -> hashref
my $fetch_info_fn;      # coderef: ($symbol, $method) -> hashref
my $fetch_currency_fn;  # coderef: ($from, $to) -> hashref or undef

sub configure {
    my (%opts) = @_;
    $fetch_quotes_fn   = $opts{fetch_quotes}   or die "FQMCP: fetch_quotes is required";
    $fetch_info_fn     = $opts{fetch_info}      or die "FQMCP: fetch_info is required";
    $fetch_currency_fn = $opts{fetch_currency}  or die "FQMCP: fetch_currency is required";
}

# ============================================
# Utility shortcuts
# ============================================

sub _json_response     { FQUtils::json_response(@_) }
sub _error_response    { FQUtils::error_response(@_) }
sub _jsonrpc_response  { FQUtils::jsonrpc_response(@_) }
sub _jsonrpc_error     { FQUtils::jsonrpc_error(@_) }
sub _json_error_response { FQUtils::json_error_response(@_) }
sub _build_cache_key   { FQUtils::build_cache_key(@_) }

# ============================================
# Main MCP dispatch
# ============================================

sub handle {
    my ($body) = @_;

    my $req;
    eval { $req = JSON::XS::decode_json($body); };
    if ($@ || !$req) {
        return _json_error_response(-32700, "Parse error", "Invalid JSON");
    }

    my $jsonrpc = $req->{jsonrpc} // '';
    my $id      = $req->{id};
    my $method  = $req->{method};
    my $params  = $req->{params} // {};

    unless ($jsonrpc eq '2.0') {
        return _json_error_response(-32600, "Invalid Request", "jsonrpc must be '2.0'");
    }

    # --- initialize ---
    if ($method eq 'initialize') {
        return _jsonrpc_response($id, {
            protocolVersion => '2024-11-05',
            capabilities    => {
                tools     => {},
                resources => {},
                prompts   => {},
            },
            serverInfo      => {
                name    => 'FinanceQuote',
                version => $FQUtils::VERSION,
            },
        });
    }

    # --- notifications/initialized ---
    if ($method eq 'notifications/initialized') {
        return [ 200, [ 'Content-Type' => 'application/json', FQUtils::standard_headers() ], [''] ];
    }

    # --- tools/list ---
    if ($method eq 'tools/list') {
        return _jsonrpc_response($id, { tools => _tool_definitions() });
    }

    # --- tools/call ---
    if ($method eq 'tools/call') {
        return _handle_tool_call($id, $params);
    }

    # --- resources/list ---
    if ($method eq 'resources/list') {
        return _jsonrpc_response($id, { resources => _resource_definitions() });
    }

    # --- resources/read ---
    if ($method eq 'resources/read') {
        return _handle_resource_read($id, $params);
    }

    # --- prompts/list ---
    if ($method eq 'prompts/list') {
        return _jsonrpc_response($id, { prompts => _prompt_definitions() });
    }

    # --- prompts/get ---
    if ($method eq 'prompts/get') {
        return _handle_prompt_get($id, $params);
    }

    return _jsonrpc_error($id, -32601, "Method not found",
        "Unknown method: $method. Supported: initialize, tools/list, tools/call, resources/list, resources/read, prompts/list, prompts/get");
}

# ============================================
# Tool Call Dispatch
# ============================================

sub _handle_tool_call {
    my ($id, $params) = @_;
    my $tool_name = $params->{name};
    my $tool_args = $params->{arguments} // {};

    # --- Composite tools ---

    if ($tool_name eq 'analyze_symbol') {
        my $query    = $tool_args->{symbol} // '';
        my $method   = $tool_args->{method} // 'yahooJSON';
        my $currency = $tool_args->{currency} // '';

        return _jsonrpc_error($id, -32602, "Invalid params", "symbol is required")
            unless $query;

        my $analysis = {};

        # Step 1: DB lookup (exact match first)
        my $db_info = FQDB::lookup_symbol($query);
        if ($db_info) {
            $analysis->{database} = $db_info;
        } else {
            my $results = FQDB::search($query, '', 5, { primary_only => 1 });
            if ($results && @$results) {
                $analysis->{database} = $results->[0];
                $analysis->{search_matches} = scalar(@$results);
                $query = $results->[0]{symbol} if $results->[0]{symbol};
            }
        }

        # Step 2: Live quote
        eval {
            my $cache_key = _build_cache_key('quote', $query, $method, $currency);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $parsed = JSON::XS::decode_json($cached->[2][0]);
                $analysis->{quote} = $parsed->{data};
            } else {
                my $result = $fetch_quotes_fn->($query, $method, $currency);
                my $response = _json_response('success', $result);
                FQCache::set($cache_key, $response);
                $analysis->{quote} = $result;
            }
        };

        # Step 3: Detailed info
        eval {
            my $cache_key = _build_cache_key('info', $query, $method);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $parsed = JSON::XS::decode_json($cached->[2][0]);
                $analysis->{info} = $parsed->{data};
            } else {
                my $info = $fetch_info_fn->($query, $method);
                my $response = _json_response('success', $info);
                FQCache::set($cache_key, $response);
                $analysis->{info} = $info;
            }
        };

        $analysis->{symbol} = $query;
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($analysis) }] });
    }

    if ($tool_name eq 'get_portfolio') {
        my $symbols_str = $tool_args->{symbols} // '';
        my $method      = $tool_args->{method} // 'yahooJSON';
        my $currency    = $tool_args->{currency} // '';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "symbols is required. Provide comma-separated symbols like AAPL,MSFT,GOOGL")
            unless $symbols_str;

        my @syms = split(/,/, $symbols_str);
        my %portfolio;

        foreach my $sym (@syms) {
            $sym =~ s/^\s+|\s+$//g;
            next unless $sym;

            my $cache_key = _build_cache_key('quote', $sym, $method, $currency);
            my $cached = FQCache::get($cache_key);
            if ($cached) {
                my $parsed = JSON::XS::decode_json($cached->[2][0]);
                $portfolio{$sym} = $parsed->{data}{$sym} // $parsed->{data};
            } else {
                eval {
                    my $result = $fetch_quotes_fn->($sym, $method, $currency);
                    my $response = _json_response('success', $result);
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
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($output) }] });
    }

    if ($tool_name eq 'compare_symbols') {
        my $symbols_str = $tool_args->{symbols} // '';
        my $method      = $tool_args->{method} // 'yahooJSON';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "symbols is required. Provide 2+ comma-separated symbols like AAPL,MSFT")
            unless $symbols_str;

        my @syms = split(/,/, $symbols_str);
        return _jsonrpc_error($id, -32602, "Invalid params",
            "Provide at least 2 symbols to compare")
            unless @syms >= 2;

        my @comparison;
        foreach my $sym (@syms) {
            $sym =~ s/^\s+|\s+$//g;
            next unless $sym;

            my $entry = { symbol => $sym };

            eval {
                my $cache_key = _build_cache_key('info', $sym, $method);
                my $cached = FQCache::get($cache_key);
                if ($cached) {
                    my $parsed = JSON::XS::decode_json($cached->[2][0]);
                    $entry = { %$entry, %{$parsed->{data}} };
                } else {
                    my $info = $fetch_info_fn->($sym, $method);
                    my $response = _json_response('success', $info);
                    FQCache::set($cache_key, $response);
                    $entry = { %$entry, %$info };
                }
            };

            eval {
                my $db_info = FQDB::lookup_symbol($sym);
                if ($db_info) {
                    $entry->{sector}     //= $db_info->{sector};
                    $entry->{country}    //= $db_info->{country};
                    $entry->{market_cap} //= $db_info->{market_cap};
                    $entry->{industry}   //= $db_info->{industry};
                }
            };

            push @comparison, $entry;
        }

        my $output = {
            comparison => \@comparison,
            fields     => [qw(symbol name exchange close high low pe yield cap volume currency)],
        };
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($output) }] });
    }

    # --- Core data tools ---

    if ($tool_name eq 'get_quote') {
        my $symbols  = $tool_args->{symbols} // '';
        my $method   = $tool_args->{method} // 'yahooJSON';
        my $currency = $tool_args->{currency} // '';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "symbols is required. Provide comma-separated ticker symbols like AAPL,MSFT")
            unless $symbols;

        my $cache_key = _build_cache_key('quote', $symbols, $method, $currency);
        my $cached = FQCache::get($cache_key);
        if ($cached) {
            my $body   = $cached->[2][0];
            my $parsed = JSON::XS::decode_json($body);
            return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
        }

        my $result   = $fetch_quotes_fn->($symbols, $method, $currency);
        my $response = _json_response('success', $result);
        FQCache::set($cache_key, $response);
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
    }

    if ($tool_name eq 'get_currency') {
        my $from = $tool_args->{from} // '';
        my $to   = $tool_args->{to} // '';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "from and to are required. Use ISO 4217 codes like USD, EUR, GBP")
            unless $from && $to;

        my $cache_key = _build_cache_key('currency', $from, $to);
        my $cached = FQCache::get($cache_key);
        if ($cached) {
            my $body   = $cached->[2][0];
            my $parsed = JSON::XS::decode_json($body);
            return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
        }

        my $rate_data = $fetch_currency_fn->($from, $to);
        if ($rate_data) {
            my $response = _json_response('success', $rate_data);
            FQCache::set($cache_key, $response);
            return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($rate_data) }] });
        }
        return _jsonrpc_error($id, -32001, "Currency conversion failed",
            "Cannot convert $from to $to. Verify both are valid ISO 4217 currency codes. Try setting ALPHAVANTAGE_API_KEY for broader coverage.");
    }

    if ($tool_name eq 'list_methods') {
        my @methods = @Finance::Quote::MODULES;
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ methods => \@methods, count => scalar(@methods) }) }] });
    }

    if ($tool_name eq 'get_symbol_info') {
        my $symbol = $tool_args->{symbol} // '';
        my $method = $tool_args->{method} // 'yahooJSON';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "symbol is required. Provide a ticker symbol like AAPL or MSFT")
            unless $symbol;

        my $cache_key = _build_cache_key('info', $symbol, $method);
        my $cached = FQCache::get($cache_key);
        if ($cached) {
            my $body   = $cached->[2][0];
            my $parsed = JSON::XS::decode_json($body);
            return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($parsed->{data}) }] });
        }

        my $info     = $fetch_info_fn->($symbol, $method);
        my $response = _json_response('success', $info);
        FQCache::set($cache_key, $response);
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($info) }] });
    }

    # --- Database discovery tools ---

    if ($tool_name eq 'search_assets') {
        my $query   = $tool_args->{query} // '';
        my $type    = $tool_args->{type} // '';
        my $limit   = $tool_args->{limit} // 20;
        my $primary = $tool_args->{primary} // 0;

        return _jsonrpc_error($id, -32602, "Invalid params",
            "query is required. Search by company name (e.g., 'Apple'), ticker (e.g., 'AAPL'), or ISIN")
            unless $query;

        my $results = FQDB::search($query, $type, $limit, { primary_only => $primary });
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
    }

    if ($tool_name eq 'lookup_symbol') {
        my $symbol = $tool_args->{symbol} // '';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "symbol is required. Provide an exact ticker symbol like AAPL")
            unless $symbol;

        my $result = FQDB::lookup_symbol($symbol);
        if ($result) {
            return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
        }
        return _jsonrpc_error($id, -32002, "Symbol not found",
            "No data found for '$symbol'. Try search_assets to find the correct ticker symbol.");
    }

    if ($tool_name eq 'filter_assets') {
        my $type = $tool_args->{type} // '';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "type is required. Valid types: equities, etfs, funds, indices, currencies, cryptos, moneymarkets. " .
            "Each type has different filter columns - use get_filter_options to discover them.")
            unless $type;

        # Pass all tool_args through to FQDB::filter() which validates per-type
        my %filter_args = (
            type  => $type,
            limit => $tool_args->{limit} // 100,
        );
        # Forward all filter params dynamically (FQDB validates per-type)
        for my $key (keys %$tool_args) {
            next if $key eq 'type' || $key eq 'limit';
            $filter_args{$key} = $tool_args->{$key};
        }

        my $results = FQDB::filter(%filter_args);
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ results => $results, count => scalar(@$results) }) }] });
    }

    if ($tool_name eq 'get_filter_options') {
        my $type = $tool_args->{type} // 'equities';
        my $options = FQDB::get_filter_options($type);
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($options) }] });
    }

    if ($tool_name eq 'get_asset_types') {
        my $types = FQDB::asset_types();
        my $stats = FQDB::stats();
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({ types => $types, stats => $stats }) }] });
    }

    if ($tool_name eq 'get_db_stats') {
        my $stats = FQDB::stats();
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($stats) }] });
    }

    # --- History tools ---

    if ($tool_name eq 'get_price_history') {
        my $symbol = $tool_args->{symbol} // '';

        return _jsonrpc_error($id, -32602, "Invalid params",
            "symbol is required. Example: AAPL")
            unless $symbol;

        my $history = FQDB::get_history(
            symbol => $symbol,
            from   => $tool_args->{from},
            to     => $tool_args->{to},
            limit  => $tool_args->{limit} // 365,
            method => $tool_args->{method},
        );
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({
            symbol  => uc($symbol),
            records => $history,
            count   => scalar(@$history),
        }) }] });
    }

    if ($tool_name eq 'get_history_overview') {
        my $symbols = FQDB::get_history_symbols();
        my $stats   = FQDB::history_stats();
        return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json({
            symbols => $symbols,
            stats   => $stats,
        }) }] });
    }

    return _jsonrpc_error($id, -32601, "Tool not found",
        "Unknown tool: $tool_name. Use tools/list to see available tools.");
}

# ============================================
# Tool Definitions
# ============================================

sub _tool_definitions {
    return [
        # --- Composite tools (recommended for most use cases) ---
        {
            name => 'analyze_symbol',
            description => 'All-in-one symbol analysis. Given a company name or ticker symbol, returns database metadata (sector, country, exchange, ISIN), live quote (price, change, volume), and detailed info (PE, yield, market cap) in a single call. START HERE if you need comprehensive data about a stock. Prices are returned in the server default currency (FQ_CURRENCY) unless overridden. Example: symbol="AAPL" or symbol="Apple". Returns: { database: {...}, quote: {...}, info: {...} }',
            inputSchema => {
                type => 'object',
                properties => {
                    symbol   => { type => 'string', description => 'Ticker symbol (e.g., AAPL) or company name (e.g., Apple). Names are auto-resolved to tickers.' },
                    method   => { type => 'string', description => 'Data source (default: yahooJSON). Use list_methods to see all available sources.' },
                    currency => { type => 'string', description => 'Convert prices to this currency (ISO 4217, e.g., EUR, GBP). Optional: server default currency (FQ_CURRENCY) is used automatically.' },
                },
                required => ['symbol'],
            },
        },
        {
            name => 'get_portfolio',
            description => 'Fetch live quotes for multiple symbols in one call. Ideal for portfolio tracking, watchlists, or batch price checks. Returns per-symbol quote data including last price, change, volume, and day range. Prices are returned in the server default currency (FQ_CURRENCY) unless overridden. Example: symbols="AAPL,MSFT,GOOGL,AMZN". Returns: { portfolio: { AAPL: {...}, MSFT: {...} }, count: N }',
            inputSchema => {
                type => 'object',
                properties => {
                    symbols  => { type => 'string', description => 'Comma-separated ticker symbols (e.g., AAPL,MSFT,GOOGL,AMZN,TSLA)' },
                    method   => { type => 'string', description => 'Data source (default: yahooJSON)' },
                    currency => { type => 'string', description => 'Convert all prices to this currency (ISO 4217). Optional: server default currency (FQ_CURRENCY) is used automatically.' },
                },
                required => ['symbols'],
            },
        },
        {
            name => 'compare_symbols',
            description => 'Side-by-side comparison of 2 or more stocks. Returns price, PE ratio, dividend yield, market cap, sector, country, and volume for each symbol. Prices are in the server default currency (FQ_CURRENCY). Use this when comparing investment options. Example: symbols="AAPL,MSFT,GOOGL". Returns: { comparison: [{symbol, close, pe, yield, cap, ...}, ...] }',
            inputSchema => {
                type => 'object',
                properties => {
                    symbols => { type => 'string', description => 'Comma-separated symbols to compare (minimum 2, e.g., AAPL,MSFT)' },
                    method  => { type => 'string', description => 'Data source (default: yahooJSON)' },
                },
                required => ['symbols'],
            },
        },
        # --- Core data tools ---
        {
            name => 'get_quote',
            description => 'Fetch raw live quotes for one or more symbols. Returns per-symbol hash with fields: last, close, open, high, low, volume, change, p_change, currency, date, time, name, exchange, method, success. Prices are returned in the server default currency (FQ_CURRENCY) unless overridden. Use get_portfolio for multiple symbols or analyze_symbol for comprehensive data. Example: symbols="AAPL,MSFT"',
            inputSchema => {
                type => 'object',
                properties => {
                    symbols  => { type => 'string', description => 'Comma-separated ticker symbols (e.g., AAPL or AAPL,MSFT,GOOGL)' },
                    method   => { type => 'string', description => 'Data source. Common: yahooJSON (default, best coverage), AlphaVantage (needs API key). Use list_methods for all.' },
                    currency => { type => 'string', description => 'Convert prices to this currency (ISO 4217, e.g., EUR). Optional: server default currency (FQ_CURRENCY) is used automatically.' },
                },
                required => ['symbols'],
            },
        },
        {
            name => 'get_symbol_info',
            description => 'Get detailed metadata for a single stock symbol. Prices are in the server default currency (FQ_CURRENCY). Returns: symbol, name, exchange, currency, close, open, high, low, volume, pe, eps, div, yield, cap, year_high, year_low, day_range, year_range, pct_change. Use analyze_symbol instead if you also need database metadata.',
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
            description => 'Get the exchange rate between two currencies. Returns: { from, to, rate }. To convert an amount, multiply by the rate. Example: from=USD, to=EUR returns { rate: 0.92 }. Note: quote tools already return prices in the server default currency (FQ_CURRENCY), so explicit conversion is rarely needed.',
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
            description => 'Search the financial database by name, ticker, ISIN, or type-specific fields. Searches across all asset types with type-appropriate columns: equities search symbol/name/isin, etfs/funds search symbol/name/category/family, currencies search symbol/name/base_currency/quote_currency, cryptos search symbol/name/cryptocurrency. Returns type-appropriate result fields. Use primary=true for major exchanges only. Example: query="Apple" or query="Bitcoin" type="cryptos"',
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
            description => 'Get exact database record for a ticker symbol. Returns all type-specific fields (e.g., equities: sector, country, industry, market_cap, isin; etfs: category_group, category, family; currencies: base_currency, quote_currency; cryptos: cryptocurrency). Returns error if not found - use search_assets first.',
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
            description => 'Filter assets by type-specific criteria. IMPORTANT: different asset types have different filter columns! Use get_filter_options(type) first to discover valid filters. Filter columns per type: equities: sector, country, exchange, market_cap, industry, industry_group, currency, market. etfs/funds: category_group, category, family, exchange, currency, market. indices: category_group, category, exchange, currency, market. currencies: base_currency, quote_currency, exchange. cryptos: cryptocurrency, currency, exchange. moneymarkets: currency, family. Returns matching assets with type-appropriate fields.',
            inputSchema => {
                type => 'object',
                properties => {
                    type           => { type => 'string',  description => 'Asset type (required): equities, etfs, funds, indices, currencies, cryptos, moneymarkets' },
                    sector         => { type => 'string',  description => '[equities] Sector (e.g., Technology, Healthcare). Use get_filter_options to see valid values.' },
                    industry       => { type => 'string',  description => '[equities] Industry (partial match, e.g., "Software", "Semiconductors")' },
                    industry_group => { type => 'string',  description => '[equities] Industry group (e.g., "Semiconductors & Semiconductor Equipment")' },
                    country        => { type => 'string',  description => '[equities] Country (e.g., United States, China, Germany)' },
                    exchange       => { type => 'string',  description => '[equities/etfs/funds/indices/currencies/cryptos] Exchange code (e.g., NMS, NYQ, LSE)' },
                    market         => { type => 'string',  description => '[equities/etfs/funds/indices] Market (e.g., us_market, gb_market)' },
                    market_cap     => { type => 'string',  description => '[equities] Market cap tier: Large Cap, Mid Cap, Small Cap, Mega Cap, Micro Cap, Nano Cap' },
                    currency       => { type => 'string',  description => '[equities/etfs/funds/indices/cryptos/moneymarkets] Currency code (e.g., USD, EUR)' },
                    category_group => { type => 'string',  description => '[etfs/funds/indices] Category group (e.g., "Equity", "Fixed Income")' },
                    category       => { type => 'string',  description => '[etfs/funds/indices] Category (partial match, e.g., "Large Growth", "Technology")' },
                    family         => { type => 'string',  description => '[etfs/funds/moneymarkets] Fund family (e.g., "Vanguard", "iShares", "Fidelity")' },
                    base_currency  => { type => 'string',  description => '[currencies] Base currency code (e.g., USD, EUR, GBP)' },
                    quote_currency => { type => 'string',  description => '[currencies] Quote currency code (e.g., USD, EUR, JPY)' },
                    cryptocurrency => { type => 'string',  description => '[cryptos] Cryptocurrency name (e.g., Bitcoin, Ethereum, Solana)' },
                    limit          => { type => 'integer', description => 'Max results (default: 100)' },
                },
                required => ['type'],
            },
        },
        {
            name => 'get_filter_options',
            description => 'Get available filter values for a given asset type. CRITICAL: each type has DIFFERENT filters! Call this BEFORE filter_assets. Examples: type=equities returns { sectors, countries, exchanges, market_caps, industries, ... }. type=etfs returns { category_groups, categories, families, exchanges, currencies }. type=currencies returns { base_currencies, quote_currencies, exchanges }. type=cryptos returns { cryptocurrencies, currencies, exchanges }.',
            inputSchema => {
                type => 'object',
                properties => {
                    type => { type => 'string', description => 'Asset type: equities, etfs, funds, indices, currencies, cryptos, moneymarkets (default: equities)' },
                },
            },
        },
        {
            name => 'get_asset_types',
            description => 'List all available asset types in the database with descriptions, row counts, and available filter columns for each type. Returns: { types: [{name, description, filters: [...]}], stats: {equities: N, etfs: N, ...} }. Call this first to understand what data is available and what filters apply to each type.',
            inputSchema => { type => 'object', properties => {} },
        },
        # --- History tools ---
        {
            name => 'get_price_history',
            description => 'Get historical quote data for a symbol. Returns daily records (close, open, high, low, volume, PE, yield, cap, etc.) from previous fetches. Data accumulates over time as quotes are fetched. Use from/to for date ranges. Returns: { symbol, records: [{date, close, open, high, low, volume, pe, yield, cap, ...}], count }. Example: symbol="AAPL", from="2024-01-01"',
            inputSchema => {
                type => 'object',
                properties => {
                    symbol => { type => 'string',  description => 'Ticker symbol (e.g., AAPL, MSFT)' },
                    from   => { type => 'string',  description => 'Start date (YYYY-MM-DD). Example: "2024-01-01"' },
                    to     => { type => 'string',  description => 'End date (YYYY-MM-DD). Example: "2024-12-31"' },
                    limit  => { type => 'integer', description => 'Max records (default: 365)' },
                    method => { type => 'string',  description => 'Filter by data source method' },
                },
                required => ['symbol'],
            },
        },
        {
            name => 'get_history_overview',
            description => 'Get an overview of all symbols with historical data. Returns list of symbols with their date ranges and number of daily records. Useful to see what historical data is available before querying get_price_history.',
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
# Resource Definitions & Reader
# ============================================

sub _resource_definitions {
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

sub _handle_resource_read {
    my ($id, $params) = @_;
    my $uri = $params->{uri} // '';

    if ($uri eq 'financequote://methods') {
        my @methods = @Finance::Quote::MODULES;
        my $content = encode_json({ methods => \@methods, count => scalar(@methods) });
        return _jsonrpc_response($id, {
            contents => [{
                uri      => $uri,
                mimeType => 'application/json',
                text     => $content,
            }],
        });
    }

    if ($uri eq 'financequote://asset-types') {
        my $types   = FQDB::asset_types();
        my $stats   = FQDB::stats();
        my $content = encode_json({ types => $types, stats => $stats });
        return _jsonrpc_response($id, {
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
            name         => 'FinanceQuote API',
            version      => $FQUtils::VERSION,
            cache        => $cache_stats,
            capabilities => [qw(quotes currency_conversion symbol_info asset_search portfolio_tracking)],
        });
        return _jsonrpc_response($id, {
            contents => [{
                uri      => $uri,
                mimeType => 'application/json',
                text     => $content,
            }],
        });
    }

    return _jsonrpc_error($id, -32002, "Resource not found",
        "Unknown resource URI: $uri. Use resources/list to see available resources.");
}

# ============================================
# Prompt Definitions & Handler
# ============================================

sub _prompt_definitions {
    return [
        {
            name        => 'analyze_stock',
            description => 'Comprehensive stock analysis: fetches live price, detailed fundamentals (PE, yield, market cap), and database metadata (sector, country, exchange). Provides a structured summary with key metrics.',
            arguments   => [
                { name => 'symbol', description => 'Ticker symbol or company name (e.g., AAPL, "Microsoft")', required => JSON::XS::true },
            ],
        },
        {
            name        => 'compare_investments',
            description => 'Side-by-side investment comparison of 2 or more stocks. Compares price, valuation (PE), yield, market cap, and sector. Helps evaluate which investment may be more attractive.',
            arguments   => [
                { name => 'symbols', description => 'Comma-separated ticker symbols to compare (e.g., AAPL,MSFT,GOOGL)', required => JSON::XS::true },
            ],
        },
        {
            name        => 'market_screener',
            description => 'Screen stocks by sector, country, exchange, or market cap. Finds matching assets in the database and optionally fetches live quotes for the top results.',
            arguments   => [
                { name => 'sector',     description => 'Sector to screen (e.g., Technology, Healthcare). Use get_filter_options to discover valid values.', required => JSON::XS::false },
                { name => 'country',    description => 'Country filter (e.g., United States, Germany)',    required => JSON::XS::false },
                { name => 'market_cap', description => 'Market cap tier (e.g., Large Cap, Mega Cap)',      required => JSON::XS::false },
            ],
        },
        {
            name        => 'currency_check',
            description => 'Quick currency exchange rate lookup between two currencies. Provides the current rate and context about the currency pair.',
            arguments   => [
                { name => 'from', description => 'Source currency code (e.g., USD, GBP)', required => JSON::XS::true },
                { name => 'to',   description => 'Target currency code (e.g., EUR, JPY)', required => JSON::XS::true },
            ],
        },
    ];
}

sub _handle_prompt_get {
    my ($id, $params) = @_;
    my $name = $params->{name} // '';
    my $args = $params->{arguments} // {};

    if ($name eq 'analyze_stock') {
        my $symbol = $args->{symbol} // 'AAPL';
        return _jsonrpc_response($id, {
            description => "Comprehensive analysis of $symbol",
            messages => [
                {
                    role    => 'user',
                    content => {
                        type => 'text',
                        text => "Analyze the stock $symbol. Use the analyze_symbol tool to get comprehensive data including database metadata, live quote, and detailed fundamentals. Then provide a structured summary covering:\n\n1. **Company Overview** - Name, sector, industry, country, exchange\n2. **Current Price** - Last price, day change (%), day range\n3. **Valuation** - P/E ratio, EPS, market cap\n4. **Income** - Dividend yield, dividend amount\n5. **52-Week Performance** - Year high, year low, current position in range\n6. **Key Takeaway** - Brief assessment based on the data\n\nAll prices are in the server's configured default currency unless I specify otherwise.",
                    },
                },
            ],
        });
    }

    if ($name eq 'compare_investments') {
        my $symbols = $args->{symbols} // 'AAPL,MSFT';
        return _jsonrpc_response($id, {
            description => "Investment comparison: $symbols",
            messages => [
                {
                    role    => 'user',
                    content => {
                        type => 'text',
                        text => "Compare these stocks side by side: $symbols. Use the compare_symbols tool to get price, PE ratio, dividend yield, market cap, sector, and volume for each. Then present:\n\n1. **Comparison Table** - Key metrics side by side\n2. **Valuation** - Which looks cheaper by PE? Which has better yield?\n3. **Size & Sector** - Market cap comparison, same/different sectors\n4. **Summary** - Brief comparison highlighting key differences\n\nAll prices are in the server's configured default currency.",
                    },
                },
            ],
        });
    }

    if ($name eq 'market_screener') {
        my $sector     = $args->{sector} // '';
        my $country    = $args->{country} // '';
        my $market_cap = $args->{market_cap} // '';

        my @criteria;
        push @criteria, "sector: $sector"     if $sector;
        push @criteria, "country: $country"   if $country;
        push @criteria, "market cap: $market_cap" if $market_cap;
        my $criteria_text = @criteria ? join(', ', @criteria) : 'Technology sector, Large Cap, United States';

        return _jsonrpc_response($id, {
            description => "Market screening: $criteria_text",
            messages => [
                {
                    role    => 'user',
                    content => {
                        type => 'text',
                        text => "Screen the market for assets matching: $criteria_text.\n\nSteps:\n1. If no criteria provided, first use get_asset_types to see available types, then get_filter_options for the chosen type to show available filter values. IMPORTANT: different asset types have different filters (e.g., equities use sector/country/market_cap, etfs use category_group/category/family, currencies use base_currency/quote_currency).\n2. Use filter_assets with type and the criteria to find matching assets (limit to 10).\n3. For the top 5 results, use get_portfolio to fetch live quotes.\n4. Present a summary table with relevant columns for the asset type.\n\nAll prices are in the server's configured default currency.",
                    },
                },
            ],
        });
    }

    if ($name eq 'currency_check') {
        my $from = $args->{from} // 'USD';
        my $to   = $args->{to} // 'EUR';
        return _jsonrpc_response($id, {
            description => "Exchange rate: $from to $to",
            messages => [
                {
                    role    => 'user',
                    content => {
                        type => 'text',
                        text => "Get the current exchange rate from $from to $to using the get_currency tool. Present the rate clearly, and show what 1, 10, 100, and 1000 $from would be in $to.",
                    },
                },
            ],
        });
    }

    return _jsonrpc_error($id, -32002, "Prompt not found",
        "Unknown prompt: $name. Use prompts/list to see available prompts.");
}

1;
