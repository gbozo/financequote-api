package FQDB;

use strict;
use warnings;
use DBI;

my $db_path = '/tmp/finance_database.db';
my $dbh;

# Whitelist of valid table names to prevent SQL injection
my %VALID_TABLES = map { $_ => 1 } qw(equities etfs funds indices currencies cryptos moneymarkets);

sub _validate_table {
    my ($type) = @_;
    my $t = lc($type // '');
    return $t if $VALID_TABLES{$t};
    return undef;
}

sub get_connection {
    # Reconnect if handle is stale or lost
    if ($dbh) {
        my $ok = eval { $dbh->do("SELECT 1"); 1 };
        unless ($ok) {
            eval { $dbh->disconnect };
            $dbh = undef;
        }
    }
    return $dbh if $dbh;
    $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
        PrintError => 1,
        RaiseError => 0,
    });
    if ($dbh) {
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

sub search {
    my ($query, $type, $limit, $opts) = @_;
    $limit //= 20;
    $query =~ s/['"]//g;
    
    my $db = get_connection();
    return [] unless $db;
    
    my $primary_only = $opts->{primary_only} // 0;
    
    my @primary_exchanges = ('NMS', 'NAS', 'NYS', 'NYQ', 'NCM', 'LSE', 'HKG', 'JPX', 'ASX', 'NSE', 'TWO', 'KOE', 'KSC', 'SES', 'SET', 'STO', 'CPH', 'HEL', 'OSL', 'VIE', 'AMS', 'PAR', 'MIL', 'FRA', 'MUN', 'DUS', 'BER', 'BRU', 'LIS', 'MAD');
    
    my @tables;
    if ($type) {
        my $valid = _validate_table($type);
        return [] unless $valid;
        @tables = ($valid);
    } else {
        @tables = sort keys %VALID_TABLES;
    }
    my @results;
    
    foreach my $table (@tables) {
        my $where_clause = "WHERE (symbol LIKE ? OR name LIKE ? OR isin LIKE ?)";
        my @bind = ("%$query%", "%$query%", "%$query%");
        
        if ($primary_only) {
            my $placeholders = join(",", ("?") x scalar(@primary_exchanges));
            $where_clause .= " AND exchange IN ($placeholders)";
            push @bind, @primary_exchanges;
        }
        
        push @bind, $limit;
        
        my $stmt = "SELECT symbol, name, exchange, country, sector, market_cap, isin FROM $table $where_clause LIMIT ?";
        my $sth = eval { $db->prepare($stmt) };
        next unless $sth;
        $sth->execute(@bind);
        
        while (my $row = $sth->fetchrow_hashref) {
            $row->{type} = $table;
            push @results, $row;
        }
        $sth->finish;
        
        last if scalar(@results) >= $limit;
    }
    
    return \@results;
}

sub lookup_symbol {
    my ($symbol, $types) = @_;
    $symbol =~ s/['"]//g;
    $symbol = uc($symbol);
    
    my $db = get_connection();
    return {} unless $db;
    
    my @tables;
    if ($types && @$types) {
        @tables = grep { _validate_table($_) } @$types;
    } else {
        @tables = sort keys %VALID_TABLES;
    }
    
    foreach my $table (@tables) {
        my $valid = _validate_table($table);
        next unless $valid;
        my $stmt = "SELECT * FROM $valid WHERE symbol = ?";
        my $sth = eval { $db->prepare($stmt) };
        next unless $sth;
        $sth->execute($symbol);
        
        if (my $row = $sth->fetchrow_hashref) {
            $sth->finish;
            $row->{type} = $valid;
            return $row;
        }
        $sth->finish;
    }
    
    return undef;
}

sub filter {
    my (%opts) = @_;
    
    my $db = get_connection();
    return [] unless $db;
    
    my $type = _validate_table($opts{type} // 'equities');
    return [] unless $type;
    
    my $sector = $opts{sector};
    my $country = $opts{country};
    my $exchange = $opts{exchange};
    my $market_cap = $opts{market_cap};
    my $industry = $opts{industry};
    my $limit = $opts{limit} // 100;
    
    my @conditions;
    my @params;
    
    if ($sector)     { push @conditions, "sector = ?";       push @params, $sector; }
    if ($country)    { push @conditions, "country = ?";      push @params, $country; }
    if ($exchange)   { push @conditions, "exchange = ?";     push @params, $exchange; }
    if ($market_cap) { push @conditions, "market_cap = ?";   push @params, $market_cap; }
    if ($industry)   { push @conditions, "industry LIKE ?";  push @params, "%$industry%"; }
    
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

sub get_filter_options {
    my ($type) = @_;
    $type = _validate_table($type // 'equities');
    return {} unless $type;
    
    my $db = get_connection();
    return {} unless $db;
    
    my %options;
    
    for my $col (qw(sector country exchange market_cap)) {
        my $key = $col eq 'market_cap' ? 'market_caps' : "${col}s";
        # sector -> sectors, country -> countries (close enough), etc.
        $key = 'countries' if $col eq 'country';
        
        my $sth = eval { $db->prepare("SELECT DISTINCT $col FROM $type WHERE $col IS NOT NULL ORDER BY $col") };
        next unless $sth;
        $sth->execute();
        $options{$key} = [];
        while (my $row = $sth->fetch()) {
            push @{$options{$key}}, $row->[0] if $row->[0];
        }
        $sth->finish;
    }
    
    return \%options;
}

sub stats {
    my $db = get_connection();
    return { error => "Database not available", status => "offline" } unless $db;
    
    my %stats;
    my $total = 0;
    
    foreach my $table (sort keys %VALID_TABLES) {
        my $sth = eval { $db->prepare("SELECT COUNT(*) FROM $table") };
        next unless $sth;
        $sth->execute();
        my $row = $sth->fetch();
        my $count = $row ? $row->[0] : 0;
        $stats{$table} = $count;
        $total += $count;
        $sth->finish;
    }
    
    $stats{total} = $total;
    
    return \%stats;
}

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

1;
