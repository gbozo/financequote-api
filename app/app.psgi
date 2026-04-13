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
# SQLite Database Lookup Module
# ============================================

{
    package FQDB;

    use strict;
    use warnings;
    use DBI;
    use Fcntl qw(:flock);
    
    my $db_path = '/tmp/finance_database.db';
    my $lock_path = '/tmp/finance_database.db.lock';
    my $dbh;
    my $lock_fh;
    
    sub connect {
        return $dbh if $dbh;
        $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
            PrintError => 0,
            RaiseError => 0,
        });
        if ($dbh) {
            # Enable WAL mode and busy timeout
            $dbh->do("PRAGMA journal_mode=WAL");
            $dbh->do("PRAGMA busy_timeout=30000");
            $dbh->do("PRAGMA synchronous=NORMAL");
        }
        return $dbh;
    }
    
    sub disconnect {
        $dbh->disconnect if $dbh;
        $dbh = undef;
    }
    
    # Search by name, symbol, or ISIN (LIKE query)
    sub search {
        my ($query, $type, $limit, $opts) = @_;
        $limit //= 20;
        $query =~ s/['"]//g;  # Sanitize
        
        my $db = FQDB::connect();
        return [] unless $db;
        
        my $primary_only = $opts->{primary_only} // 0;
        
        # Primary exchanges for major markets (include these, exclude others as secondary)
        my @primary_exchanges = ('NMS', 'NAS', 'NYS', 'NYQ', 'NCM', 'LSE', 'HKG', 'JPX', 'ASX', 'NSE', 'TWO', 'KOE', 'KSC', 'SES', 'SET', 'STO', 'CPH', 'HEL', 'OSL', 'VIE', 'AMS', 'PAR', 'MIL', 'FRA', 'MUN', 'DUS', 'BER', 'BRU', 'LIS', 'MAD');
        
        my @tables = $type ? ($type) : ('equities', 'etfs', 'funds', 'indices', 'currencies', 'cryptos', 'moneymarkets');
        my @results;
        
        foreach my $table (@tables) {
            my $where_clause = "WHERE (symbol LIKE ? OR name LIKE ? OR isin LIKE ?)";
            if ($primary_only) {
                my $in_list = join(",", map { "'$_'" } @primary_exchanges);
                $where_clause .= " AND exchange IN ($in_list)";
            }
            
            my $stmt = "SELECT symbol, name, exchange, country, sector, market_cap, isin FROM $table $where_clause LIMIT ?";
            my $sth = eval { $db->prepare($stmt) };
            next unless $sth;
            $sth->execute("%$query%", "%$query%", "%$query%", $limit);
            
            while (my $row = $sth->fetchrow_hashref) {
                $row->{type} = $table;
                push @results, $row;
            }
            $sth->finish;
            
            last if scalar(@results) >= $limit;
        }
        
        return \@results;
    }
    
    # Lookup by exact symbol
    sub lookup_symbol {
        my ($symbol, $types) = @_;
        $symbol =~ s/['"]//g;
        $symbol = uc($symbol);
        
        my $db = FQDB::connect();
        return {} unless $db;
        
        my @tables = $types ? @$types : ('equities', 'etfs', 'funds', 'indices', 'currencies', 'cryptos', 'moneymarkets');
        
        foreach my $table (@tables) {
            my $stmt = "SELECT * FROM $table WHERE symbol = ?";
            my $sth = eval { $db->prepare($stmt) };
            next unless $sth;
            $sth->execute($symbol);
            
            if (my $row = $sth->fetchrow_hashref) {
                $sth->finish;
                $row->{type} = $table;
                return $row;
            }
            $sth->finish;
        }
        
        return undef;
    }
    
    # Filter by multiple criteria
    sub filter {
        my (%opts) = @_;
        
        my $db = FQDB::connect();
        return [] unless $db;
        
        my $type = $opts{type} // 'equities';
        my $sector = $opts{sector};
        my $country = $opts{country};
        my $exchange = $opts{exchange};
        my $market_cap = $opts{market_cap};
        my $industry = $opts{industry};
        my $limit = $opts{limit} // 100;
        
        my @conditions;
        my @params;
        
        push @conditions, "sector = ?" and push @params, $sector if $sector;
        push @conditions, "country = ?" and push @params, $country if $country;
        push @conditions, "exchange = ?" and push @params, $exchange if $exchange;
        push @conditions, "market_cap = ?" and push @params, $market_cap if $market_cap;
        push @conditions, "industry LIKE ?" and push @params, "%$industry%" if $industry;
        
        my $where = @conditions ? "WHERE " . join(" AND ", @conditions) : "";
        
        my $stmt = "SELECT symbol, name, exchange, country, sector, industry, market_cap FROM $type $where LIMIT ?";
        push @params, $limit;
        
        my $sth = eval { $db->prepare($stmt) };
        return [] unless $sth;
        $sth->execute(@params);
        
        my @results;
        while (my $row = $sth->fetchrow_hashref) {
            push @results, $row;
        }
        $sth->finish;
        
        return \@results;
    }
    
    # Get available filter options
    sub get_filter_options {
        my ($type) = @_;
        $type //= 'equities';
        
        my $db = FQDB::connect();
        return {} unless $db;
        
        my %options;
        
        # Sectors
        my $sth = eval { $db->prepare("SELECT DISTINCT sector FROM $type WHERE sector IS NOT NULL ORDER BY sector") };
        return {} unless $sth;
        $sth->execute();
        $options{sectors} = [];
        while (my $row = $sth->fetch()) {
            push @{$options{sectors}}, $row->[0] if $row->[0];
        }
        $sth->finish;
        
        # Countries
        $sth = eval { $db->prepare("SELECT DISTINCT country FROM $type WHERE country IS NOT NULL ORDER BY country") };
        if ($sth) {
            $sth->execute();
            $options{countries} = [];
            while (my $row = $sth->fetch()) {
                push @{$options{countries}}, $row->[0] if $row->[0];
            }
            $sth->finish;
        }
        
        # Exchanges
        $sth = eval { $db->prepare("SELECT DISTINCT exchange FROM $type WHERE exchange IS NOT NULL ORDER BY exchange") };
        if ($sth) {
            $sth->execute();
            $options{exchanges} = [];
            while (my $row = $sth->fetch()) {
                push @{$options{exchanges}}, $row->[0] if $row->[0];
            }
            $sth->finish;
        }
        
        # Market caps
        $sth = eval { $db->prepare("SELECT DISTINCT market_cap FROM $type WHERE market_cap IS NOT NULL ORDER BY market_cap") };
        if ($sth) {
            $sth->execute();
            $options{market_caps} = [];
            while (my $row = $sth->fetch()) {
                push @{$options{market_caps}}, $row->[0] if $row->[0];
            }
            $sth->finish;
        }
        
        return \%options;
    }
    
    # Get database statistics
    sub stats {
        my $db = FQDB::connect();
        return { error => "Database not available", status => "offline" } unless $db;
        
        my %stats;
        
        my @tables = ('equities', 'etfs', 'funds', 'indices', 'currencies', 'cryptos', 'moneymarkets');
        
        foreach my $table (@tables) {
            my $sth = eval { $db->prepare("SELECT COUNT(*) FROM $table") };
            next unless $sth;
            $sth->execute();
            my $row = $sth->fetch();
            $stats{$table} = $row ? $row->[0] : 0;
            $sth->finish;
        }
        
        $stats{total} = 0;
        $stats{total} += $_ for values %stats;
        
        return \%stats;
    }
    
    # Get all asset types
    sub asset_types {
        return [
            { name => 'equities', description => 'Stock equities from global markets' },
            { name => 'etfs', description => 'Exchange-traded funds' },
            { name => 'funds', description => 'Mutual funds and investment funds' },
            { name => 'indices', description => 'Market indices' },
            { name => 'currencies', description => 'Currency pairs' },
            { name => 'cryptos', description => 'Cryptocurrencies' },
            { name => 'moneymarkets', description => 'Money market instruments' },
        ];
    }
}

# ============================================
# API Application
# ============================================

{
    package FQAPI;

    use strict;
    use warnings;
    use JSON::XS qw(encode_json decode_json);

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
    
    # Set currency BEFORE creating the quoter object
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
        my $method = $params->{method} || 'yahooJSON';
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

# 3b. Symbol Info (metadata)
    sub handle_info {
        my ($symbol, $params) = @_;
        
        # Build cache key
        my $method = $params->{method} || 'yahooJSON';
        my $cache_key = "info:${symbol}:${method}";
        
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

    # ============================================
    # MCP Protocol Handler (Model Context Protocol)
    # ============================================
    
    sub handle_mcp {
        my ($body) = @_;
        
        # Parse JSON-RPC 2.0 request
        my $req;
        eval { $req = decode_json($body); };
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
    
    sub _get_currency_rate {
        my ($from, $to) = @_;
        
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
            return $rate + 0 if $rate && $rate =~ /^-?[\d.]+$/;
        }
        
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
        
        return $rate + 0 if $rate && $rate =~ /^-?[\d.]+$/;
        return undef;
    }
    
    sub jsonrpc_response {
        my ($id, $result) = @_;
        my $json_text = '{"jsonrpc":"2.0","id":' . (defined $id ? $id : 'null') . ',"result":' . encode_json($result) . '}';
        return [ 200, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ $json_text ] ];
    }
    
    sub jsonrpc_error {
        my ($id, $code, $message, $data) = @_;
        my $json_text = '{"jsonrpc":"2.0","id":' . (defined $id ? $id : 'null') . ',"error":{"code":' . $code . ',"message":"' . $message . '","data":"' . ($data // '') . '"}}';
        return [ 200, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ $json_text ] ];
    }
    
    sub json_error_response {
        my ($code, $message, $data) = @_;
        my $json_text = '{"jsonrpc":"2.0","id":null,"error":{"code":' . $code . ',"message":"' . $message . '","data":"' . ($data // '') . '"}}';
        return [ 200, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ $json_text ] ];
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
    
    # Route: /api/v1/info/:symbol
    if ($path =~ m{^/api/v1/info/([^/]+)$}) {
        return FQAPI::handle_info($1, \%params);
    }
    
    # Route: /api/v1/currency/:from/:to
    if ($path =~ m{^/api/v1/currency/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_currency($1, $2, \%params);
    }
    
    # Route: /api/v1/fetch/:method/:symbols
    if ($path eq '/api/v1/fetch/([^/]+)/([^/]+)$') {
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
    if ($path eq '/mcp') {
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
    
    # Serve OpenAPI spec with dynamic server URL and version
    if ($path eq '/openapi.yaml') {
        open my $fh, '<', '/app/public/openapi.yaml' or return [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Cannot read file' ] ];
        my $yaml = do { local $/; <$fh> };
        close $fh;
        
        # Replace {SERVER_URL} with actual host from request
        my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME} // 'localhost:3001';
        my $scheme = $env->{'psgi.url_scheme'} // 'http';
        my $server_url = "$scheme://$host";
        $yaml =~ s/\{SERVER_URL\}/$server_url/ge;
        
        # Replace {FQ_VERSION} with Finance::Quote version
        my $fq_version = Finance::Quote->VERSION // 'unknown';
        $yaml =~ s/\{FQ_VERSION\}/$fq_version/ge;
        
        return [ 200, [ 'Content-Type' => 'text/yaml', 'Access-Control-Allow-Origin' => '*' ], [ $yaml ] ];
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