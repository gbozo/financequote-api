package FQDB;

use strict;
use warnings;
use DBI;

my $db_path = '/tmp/finance_database.db';
my $dbh;

sub get_connection {
    return $dbh if $dbh;
    $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
        PrintError => 0,
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

sub lookup_symbol {
    my ($symbol, $types) = @_;
    $symbol =~ s/['"]//g;
    $symbol = uc($symbol);
    
    my $db = get_connection();
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

sub filter {
    my (%opts) = @_;
    
    my $db = get_connection();
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

sub get_filter_options {
    my ($type) = @_;
    $type //= 'equities';
    
    my $db = get_connection();
    return {} unless $db;
    
    my %options;
    
    my $sth = eval { $db->prepare("SELECT DISTINCT sector FROM $type WHERE sector IS NOT NULL ORDER BY sector") };
    return {} unless $sth;
    $sth->execute();
    $options{sectors} = [];
    while (my $row = $sth->fetch()) {
        push @{$options{sectors}}, $row->[0] if $row->[0];
    }
    $sth->finish;
    
    $sth = eval { $db->prepare("SELECT DISTINCT country FROM $type WHERE country IS NOT NULL ORDER BY country") };
    if ($sth) {
        $sth->execute();
        $options{countries} = [];
        while (my $row = $sth->fetch()) {
            push @{$options{countries}}, $row->[0] if $row->[0];
        }
        $sth->finish;
    }
    
    $sth = eval { $db->prepare("SELECT DISTINCT exchange FROM $type WHERE exchange IS NOT NULL ORDER BY exchange") };
    if ($sth) {
        $sth->execute();
        $options{exchanges} = [];
        while (my $row = $sth->fetch()) {
            push @{$options{exchanges}}, $row->[0] if $row->[0];
        }
        $sth->finish;
    }
    
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

sub stats {
    my $db = get_connection();
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