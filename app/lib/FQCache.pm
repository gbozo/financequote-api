package FQCache;

# SQLite-backed cache with TTL.
# Replaces the previous in-memory hash cache.
# Survives container restarts (persistent volume).
# Stale entries are cleaned by cron; also cleaned on get().

use strict;
use warnings;
use JSON::XS qw(encode_json decode_json);
use DBI;

my $ttl = 900;
my $enabled = 1;
my $db_path;
my $dbh;

sub configure {
    my ($env_ttl, $env_enabled, $env_db_path) = @_;
    if (defined $env_ttl && $env_ttl =~ /^\d+$/) {
        $ttl = $env_ttl;
    }
    $enabled = defined $env_enabled ? $env_enabled : 1;
    $db_path = $env_db_path // '/data/finance_database.db';
    _init_table();
}

sub _get_dbh {
    if ($dbh) {
        my $ok = eval { $dbh->do("SELECT 1"); 1 };
        return $dbh if $ok;
        eval { $dbh->disconnect };
        $dbh = undef;
    }
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

sub _init_table {
    my $db = _get_dbh() or return;
    $db->do(q{
        CREATE TABLE IF NOT EXISTS quotes_cache (
            cache_key   TEXT PRIMARY KEY,
            status      INTEGER NOT NULL,
            headers     TEXT NOT NULL,
            body        TEXT NOT NULL,
            expires_at  INTEGER NOT NULL,
            created_at  INTEGER NOT NULL
        )
    });
    $db->do("CREATE INDEX IF NOT EXISTS idx_cache_expires ON quotes_cache(expires_at)");
}

sub get {
    my ($key) = @_;
    return undef unless $enabled;
    my $db = _get_dbh() or return undef;

    my $sth = $db->prepare("SELECT status, headers, body, expires_at FROM quotes_cache WHERE cache_key = ?");
    $sth->execute($key);
    my $row = $sth->fetchrow_arrayref;
    $sth->finish;
    return undef unless $row;

    my ($status, $headers_json, $body, $expires_at) = @$row;

    # Expired - delete and return miss
    if (time > $expires_at) {
        $db->do("DELETE FROM quotes_cache WHERE cache_key = ?", undef, $key);
        return undef;
    }

    # Reconstruct PSGI response array
    my $headers = eval { decode_json($headers_json) } // [];
    return [ $status, $headers, [ $body ] ];
}

sub set {
    my ($key, $data, $custom_ttl) = @_;
    return unless $enabled;
    return unless $data && ref($data) eq 'ARRAY' && @$data >= 3;
    my $db = _get_dbh() or return;

    my $expire_ttl = $custom_ttl || $ttl;
    my $status     = $data->[0];
    my $headers    = encode_json($data->[1] // []);
    my $body       = ref($data->[2]) eq 'ARRAY' ? $data->[2][0] : $data->[2];
    my $now        = time;

    $db->do(
        "INSERT OR REPLACE INTO quotes_cache (cache_key, status, headers, body, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        undef, $key, $status, $headers, $body, $now + $expire_ttl, $now
    );
}

sub clear {
    my $db = _get_dbh() or return;
    $db->do("DELETE FROM quotes_cache");
}

sub purge_expired {
    my $db = _get_dbh() or return 0;
    my $sth = $db->do("DELETE FROM quotes_cache WHERE expires_at < ?", undef, time);
    return $sth // 0;
}

sub stats {
    my $db = _get_dbh();
    return { enabled => $enabled, ttl => $ttl, entries => 0, expired => 0, backend => 'sqlite' }
        unless $db;

    my $now = time;
    my ($total) = $db->selectrow_array("SELECT COUNT(*) FROM quotes_cache");
    my ($expired) = $db->selectrow_array("SELECT COUNT(*) FROM quotes_cache WHERE expires_at < ?", undef, $now);

    return {
        enabled => $enabled,
        ttl     => $ttl,
        entries => ($total // 0) - ($expired // 0),
        expired => $expired // 0,
        backend => 'sqlite',
    };
}

1;
