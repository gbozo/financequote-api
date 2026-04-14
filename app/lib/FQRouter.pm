package FQRouter;

# FQRouter - HTTP routing and static file serving for FinanceQuote API
# Separates routing/middleware concerns from handler business logic.
# Developers should focus on FQAPI handlers in app.psgi, not on routing.

use strict;
use warnings;
use JSON::XS qw(encode_json);
use FQUtils;

# ============================================
# Route Dispatch
# ============================================

sub dispatch {
    my ($env, $params) = @_;
    my $path = $env->{PATH_INFO} // '/';
    my $method = $env->{REQUEST_METHOD} // 'GET';

    # --- CORS preflight ---
    if ($method eq 'OPTIONS') {
        return _cors_preflight();
    }

    # --- Authentication (exempt health and static) ---
    unless (_is_public_path($path)) {
        my $auth_result = _check_auth($env);
        return $auth_result if $auth_result;  # returns error response or undef (authorized)
    }

    # --- API Routes ---

    if ($path eq '/api/v1/health') {
        return FQAPI::handle_health();
    }

    if ($path eq '/api/v1/methods') {
        return FQAPI::handle_methods();
    }

    if ($path =~ m{^/api/v1/quote/([^/]+)$}) {
        return FQAPI::handle_quote($1, $params);
    }

    if ($path =~ m{^/api/v1/info/([^/]+)$}) {
        return FQAPI::handle_info($1, $params);
    }

    if ($path =~ m{^/api/v1/currency/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_currency($1, $2, $params);
    }

    if ($path =~ m{^/api/v1/fetch/([^/]+)/([^/]+)$}) {
        return FQAPI::handle_fetch($1, $2, $params);
    }

    # --- Database Routes ---

    if ($path eq '/api/v1/db/stats') {
        my $stats = FQDB::stats();
        return FQUtils::json_response('success', $stats);
    }

    if ($path eq '/api/v1/db/assets') {
        my $types = FQDB::asset_types();
        return FQUtils::json_response('success', { types => $types });
    }

    if ($path =~ m{^/api/v1/db/options/([^/]+)$}) {
        my $type = $1;
        my $options = FQDB::get_filter_options($type);
        return FQUtils::json_response('success', $options);
    }

    if ($path eq '/api/v1/search') {
        my $query = $params->{q} // '';
        my $type = $params->{type} // '';
        my $limit = $params->{limit} // 20;
        my $primary_only = $params->{primary} // 0;

        unless ($query) {
            return FQUtils::error_response(400, "Missing query", "Provide a search query with ?q=...");
        }

        my $results = FQDB::search($query, $type, $limit, { primary_only => $primary_only });
        return FQUtils::json_response('success', { results => $results, count => scalar(@$results) });
    }

    if ($path =~ m{^/api/v1/lookup/([^/]+)$}) {
        my $symbol = $1;
        my $result = FQDB::lookup_symbol($symbol);

        if ($result) {
            return FQUtils::json_response('success', $result);
        } else {
            return FQUtils::error_response(404, "Symbol not found", "No data found for symbol $symbol");
        }
    }

    if ($path eq '/api/v1/filter') {
        my $type = $params->{type} // 'equities';
        my @valid_types = qw(equities etfs funds indices currencies cryptos moneymarkets);
        my %valid = map { $_ => 1 } @valid_types;
        unless ($valid{$type}) {
            return FQUtils::error_response(400, "Invalid type", "Valid types: " . join(", ", @valid_types));
        }

        # Pass all params through to FQDB::filter which validates per-type
        my %filter_args = (type => $type, limit => $params->{limit} // 100);
        for my $key (keys %$params) {
            next if $key eq 'type' || $key eq 'limit';
            $filter_args{$key} = $params->{$key};
        }

        my $results = FQDB::filter(%filter_args);
        return FQUtils::json_response('success', { results => $results, count => scalar(@$results) });
    }

    # --- Quote History endpoints ---

    if ($path =~ m{^/api/v1/history/([^/]+)$}) {
        return FQAPI::handle_history($1, $params);
    }

    if ($path eq '/api/v1/history') {
        return FQAPI::handle_history_overview($params);
    }

    # --- MCP Protocol endpoint ---

    if ($path eq '/mcp' || $path eq '/mcp/sse') {
        if ($method eq 'POST') {
            my $content_length = $env->{CONTENT_LENGTH} // 0;
            my $body = '';
            if ($content_length > 0) {
                $env->{'psgi.input'}->read($body, $content_length);
            }
            return FQAPI::handle_mcp($body);
        }

        if ($method eq 'GET') {
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

        return [ 405, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ],
            [ encode_json({ jsonrpc => '2.0', error => { code => -32600, message => 'Method not allowed' } }) ] ];
    }

    # --- OpenAPI spec ---

    if ($path eq '/api/v1/spec' || $path eq '/openapi.json') {
        return _serve_openapi_json($env);
    }

    if ($path eq '/openapi.yaml') {
        return _serve_openapi_yaml($env);
    }

    # --- Static files ---

    if ($path eq '/' || $path eq '/index.html' || $path eq '/docs' || $path eq '/docs/') {
        return _serve_file('/app/public/index.html', 'text/html');
    }

    if ($path eq '/swagger' || $path eq '/swagger/') {
        return [ 302, [ 'Location' => '/', 'Access-Control-Allow-Origin' => '*' ], [ 'Redirecting...' ] ];
    }

    if ($path =~ m{^/swagger/(.+)$}) {
        return _serve_static("/app/public/swagger/$1");
    }

    # Static images - strip leading slash from capture to avoid double-slash
    if ($path =~ m{^/([^/]+\.(?:jpg|jpeg|png|gif|svg))$}) {
        my $filename = $1;
        return _serve_static("/app/public/$filename");
    }

    # --- 404 ---
    return FQUtils::error_response(404, "Not Found", "Path $path not found");
}

# ============================================
# Query String Parsing
# ============================================

sub parse_query_string {
    my ($qs) = @_;
    my %params;
    return \%params unless $qs;
    foreach my $pair (split(/&/, $qs)) {
        my ($k, $v) = split(/=/, $pair, 2);
        next unless $k;
        $params{FQUtils::url_decode($k)} = FQUtils::url_decode($v // '');
    }
    return \%params;
}

# ============================================
# Internal Helpers
# ============================================

sub _cors_preflight {
    return [ 200, [
        'Content-Type' => 'application/json',
        'Access-Control-Allow-Origin' => '*',
        'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers' => 'Content-Type, Authorization',
    ], [] ];
}

sub _is_public_path {
    my ($path) = @_;
    # Health check and static assets don't require auth
    return 1 if $path eq '/api/v1/health';
    return 1 if $path eq '/' || $path eq '/index.html' || $path eq '/docs' || $path eq '/docs/';
    return 1 if $path =~ m{^/swagger};
    return 1 if $path =~ m{^/openapi\.(json|yaml)$};
    return 1 if $path =~ m{\.(jpg|jpeg|png|gif|svg|css|js|woff2?|ico)$};
    return 0;
}

sub _check_auth {
    my ($env) = @_;
    my $auth_keys = $ENV{'API_AUTH_KEYS'} // '';
    return undef unless $auth_keys;  # No auth configured = allow all

    my @keys = split(/,/, $auth_keys);
    my $auth_header = $env->{HTTP_AUTHORIZATION} // '';
    my $provided_key = '';

    if ($auth_header =~ /^Bearer\s+(.+)$/i) {
        $provided_key = $1;
    }

    for my $key (@keys) {
        $key =~ s/^\s+|\s+$//g;
        return undef if $key && $key eq $provided_key;  # Authorized
    }

    return FQUtils::error_response(401, 'Unauthorized', 'Invalid or missing API key. Set API_AUTH_KEYS environment variable.');
}

sub _serve_openapi_json {
    my ($env) = @_;
    my $fq_version = Finance::Quote->VERSION // 'unknown';
    my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME} // 'localhost:3001';
    my $scheme = $env->{'psgi.url_scheme'} // 'http';
    my $spec = FQUtils::get_openapi_spec(
        version    => $FQUtils::VERSION,
        fq_version => $fq_version,
    );
    $spec->{servers}[0]{url} = "$scheme://$host";
    return [ 200, [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ], [ encode_json($spec) ] ];
}

sub _serve_openapi_yaml {
    my ($env) = @_;
    my $fq_version = Finance::Quote->VERSION // 'unknown';
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

my %MIME_TYPES = (
    js    => 'application/javascript',
    css   => 'text/css',
    html  => 'text/html',
    json  => 'application/json',
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    svg   => 'image/svg+xml',
    woff  => 'font/woff',
    woff2 => 'font/woff2',
    ico   => 'image/x-icon',
);

sub _serve_static {
    my ($file_path) = @_;
    return [ 404, [ 'Content-Type' => 'text/plain', 'Access-Control-Allow-Origin' => '*' ], [ 'Not Found' ] ]
        unless -e $file_path;

    my ($ext) = ($file_path =~ /\.(\w+)$/);
    my $content_type = $MIME_TYPES{lc($ext // '')} // 'application/octet-stream';

    open my $fh, '<', $file_path or return [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Cannot read file' ] ];
    binmode $fh;
    my $content = do { local $/; <$fh> };
    close $fh;
    return [ 200, [ 'Content-Type' => $content_type, 'Access-Control-Allow-Origin' => '*' ], [ $content ] ];
}

sub _serve_file {
    my ($file_path, $content_type) = @_;
    return _serve_static($file_path);  # _serve_static detects content type, but we can override
}

1;
