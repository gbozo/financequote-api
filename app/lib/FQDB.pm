package FQDB;

use strict;
use warnings;
use DBI;

my $db_path = '/tmp/finance_database.db';
my $dbh;

# Whitelist of valid table names to prevent SQL injection
my %VALID_TABLES = map { $_ => 1 } qw(equities etfs funds indices currencies cryptos moneymarkets);

# Per-type column schemas matching the import script's TABLE_SCHEMAS
my %TABLE_COLUMNS = (
    equities => [qw(symbol name currency sector industry_group industry exchange market
                     country state city zipcode website market_cap isin cusip figi
                     composite_figi shareclass_figi summary)],
    etfs => [qw(symbol name currency summary category_group category family exchange market)],
    funds => [qw(symbol name currency summary category_group category family exchange market)],
    indices => [qw(symbol name currency summary category_group category exchange market)],
    currencies => [qw(symbol name summary exchange base_currency quote_currency)],
    cryptos => [qw(symbol name currency summary exchange cryptocurrency)],
    moneymarkets => [qw(symbol name currency summary family)],
);

# Columns to search in search() per type
my %SEARCH_COLUMNS = (
    equities    => [qw(symbol name isin)],
    etfs        => [qw(symbol name category family)],
    funds       => [qw(symbol name category family)],
    indices     => [qw(symbol name category)],
    currencies  => [qw(symbol name base_currency quote_currency)],
    cryptos     => [qw(symbol name cryptocurrency)],
    moneymarkets => [qw(symbol name family)],
);

# Columns returned by search() per type (compact result set)
my %SEARCH_RESULT_COLUMNS = (
    equities    => [qw(symbol name exchange country sector market_cap isin)],
    etfs        => [qw(symbol name exchange category_group category family)],
    funds       => [qw(symbol name exchange category_group category family)],
    indices     => [qw(symbol name exchange category_group category)],
    currencies  => [qw(symbol name exchange base_currency quote_currency)],
    cryptos     => [qw(symbol name exchange cryptocurrency currency)],
    moneymarkets => [qw(symbol name currency family)],
);

# Filterable columns per type (used by filter() and get_filter_options())
my %FILTER_COLUMNS = (
    equities    => [qw(sector country exchange market_cap industry industry_group currency market)],
    etfs        => [qw(category_group category family exchange currency market)],
    funds       => [qw(category_group category family exchange currency market)],
    indices     => [qw(category_group category exchange currency market)],
    currencies  => [qw(base_currency quote_currency exchange)],
    cryptos     => [qw(cryptocurrency currency exchange)],
    moneymarkets => [qw(currency family)],
);

# Valid column names across all types (for SQL injection prevention in dynamic queries)
my %ALL_VALID_COLUMNS;
for my $cols (values %TABLE_COLUMNS) {
    $ALL_VALID_COLUMNS{$_} = 1 for @$cols;
}

sub _validate_table {
    my ($type) = @_;
    my $t = lc($type // '');
    return $t if $VALID_TABLES{$t};
    return undef;
}

sub _validate_column {
    my ($col) = @_;
    return $ALL_VALID_COLUMNS{$col} ? $col : undef;
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

    my @primary_exchanges = ('NMS', 'NAS', 'NYS', 'NYQ', 'NCM', 'LSE', 'HKG', 'JPX',
        'ASX', 'NSE', 'TWO', 'KOE', 'KSC', 'SES', 'SET', 'STO', 'CPH', 'HEL',
        'OSL', 'VIE', 'AMS', 'PAR', 'MIL', 'FRA', 'MUN', 'DUS', 'BER', 'BRU',
        'LIS', 'MAD');

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
        # Use type-specific search columns
        my @search_cols = @{ $SEARCH_COLUMNS{$table} // [qw(symbol name)] };
        my @result_cols = @{ $SEARCH_RESULT_COLUMNS{$table} // [qw(symbol name)] };

        # Build WHERE clause with type-appropriate columns
        my @like_clauses;
        my @bind;
        for my $col (@search_cols) {
            push @like_clauses, "$col LIKE ?";
            push @bind, "%$query%";
        }
        my $where_clause = "WHERE (" . join(" OR ", @like_clauses) . ")";

        # Primary exchange filter (only for types that have exchange column)
        if ($primary_only && grep { $_ eq 'exchange' } @{ $TABLE_COLUMNS{$table} // [] }) {
            my $placeholders = join(",", ("?") x scalar(@primary_exchanges));
            $where_clause .= " AND exchange IN ($placeholders)";
            push @bind, @primary_exchanges;
        }

        push @bind, $limit;

        my $select_cols = join(", ", @result_cols);
        my $stmt = "SELECT $select_cols FROM $table $where_clause LIMIT ?";
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

        # Select all columns for this type (not *)
        my @cols = @{ $TABLE_COLUMNS{$valid} // next };
        my $select_cols = join(", ", @cols);

        my $stmt = "SELECT $select_cols FROM $valid WHERE symbol = ?";
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

    my $limit = $opts{limit} // 100;

    # Get valid filter columns for this type
    my %valid_filters = map { $_ => 1 } @{ $FILTER_COLUMNS{$type} // [] };
    my @result_cols = @{ $SEARCH_RESULT_COLUMNS{$type} // [qw(symbol name)] };

    my @conditions;
    my @params;

    # Accept any filter parameter that is valid for this type
    for my $key (keys %opts) {
        next if $key eq 'type' || $key eq 'limit';
        next unless $valid_filters{$key};
        next unless defined $opts{$key} && $opts{$key} ne '';

        # Use LIKE for text-heavy fields, exact match for others
        if ($key eq 'industry' || $key eq 'category' || $key eq 'name') {
            push @conditions, "$key LIKE ?";
            push @params, "%$opts{$key}%";
        } else {
            push @conditions, "$key = ?";
            push @params, $opts{$key};
        }
    }

    my $where = @conditions ? "WHERE " . join(" AND ", @conditions) : "";
    my $select_cols = join(", ", @result_cols);
    my $stmt = "SELECT $select_cols FROM $type $where LIMIT ?";
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

    # Return filterable columns and their distinct values for this specific type
    my @filter_cols = @{ $FILTER_COLUMNS{$type} // [] };
    my %options;

    for my $col (@filter_cols) {
        # Pluralize the key name for the response
        my $key = _pluralize($col);

        my $sth = eval { $db->prepare("SELECT DISTINCT $col FROM $type WHERE $col IS NOT NULL AND $col != '' ORDER BY $col") };
        next unless $sth;
        $sth->execute();
        $options{$key} = [];
        while (my $row = $sth->fetch()) {
            push @{$options{$key}}, $row->[0] if defined $row->[0] && $row->[0] ne '';
        }
        $sth->finish;
    }

    return \%options;
}

sub _pluralize {
    my ($col) = @_;
    return 'countries' if $col eq 'country';
    return 'industries' if $col eq 'industry';
    return 'families' if $col eq 'family';
    return 'currencies' if $col eq 'currency';
    return 'cryptocurrencies' if $col eq 'cryptocurrency';
    return 'categories' if $col eq 'category';
    return 'category_groups' if $col eq 'category_group';
    return 'industry_groups' if $col eq 'industry_group';
    return 'base_currencies' if $col eq 'base_currency';
    return 'quote_currencies' if $col eq 'quote_currency';
    return "${col}s";  # default: append 's'
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
        { name => 'equities',     description => 'Stock equities from global markets',
          filters => $FILTER_COLUMNS{equities} },
        { name => 'etfs',         description => 'Exchange-traded funds',
          filters => $FILTER_COLUMNS{etfs} },
        { name => 'funds',        description => 'Mutual funds and investment funds',
          filters => $FILTER_COLUMNS{funds} },
        { name => 'indices',      description => 'Market indices',
          filters => $FILTER_COLUMNS{indices} },
        { name => 'currencies',   description => 'Currency pairs (forex)',
          filters => $FILTER_COLUMNS{currencies} },
        { name => 'cryptos',      description => 'Cryptocurrencies',
          filters => $FILTER_COLUMNS{cryptos} },
        { name => 'moneymarkets', description => 'Money market instruments',
          filters => $FILTER_COLUMNS{moneymarkets} },
    ];
}

sub get_columns {
    my ($type) = @_;
    $type = _validate_table($type // '');
    return [] unless $type;
    return $TABLE_COLUMNS{$type} // [];
}

sub get_filter_columns {
    my ($type) = @_;
    $type = _validate_table($type // '');
    return [] unless $type;
    return $FILTER_COLUMNS{$type} // [];
}

1;
