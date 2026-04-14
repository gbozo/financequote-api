# Agent Guide - FinanceQuote API

Quick reference for agents working on this project.

## Project Overview

- **Purpose**: REST API wrapper and MCP server for Perl's Finance::Quote library (45+ financial data sources) and python module FinanceDatabase
- **Stack**: Perl 5.36+, Plack/PSGI, Starman, Docker, python, sqlite3
- **Language**: Primary is Perl (PSGI), python for db data import, client libs in Go/Python/Node
- **License**: MIT

## Key Files

| File | Purpose |
|------|---------|
| `/app/app.psgi` | Main PSGI application - all API logic lives here |
| `docker-compose.yaml` | Production deployment config |
| `docker/Dockerfile` | Container build recipe |
| `mcp.json` | LMStudio MCP server config example |

## Architecture

```
┌─────────────────┐
│  Starman (3000) │  ← Production HTTP server
└────────┬────────┘
         │
┌────────▼────────┐
│  Plack::Builder │  ← PSGI middleware/routing
└────────┬────────┘
         │
┌────────▼────────┐
│  FQAPI package  │  ← All handlers (handle_quote, handle_currency, etc.)
└────────┬────────┘
         │
┌────────▼────────┐
│ Finance::Quote  │  ← CPAN module - actual quote fetching
└─────────────────┘
```

## Important Gotchas

### 1. FQ_CURRENCY Must Be Set BEFORE Creating Quote Object

```perl
# WRONG - currency setting won't work
my $quoter = Finance::Quote->new();
$ENV{'FQ_CURRENCY'} = 'EUR';  # Too late!

# CORRECT - set BEFORE
$ENV{'FQ_CURRENCY'} = 'EUR';
my $quoter = Finance::Quote->new();
```

### 2. Finance::Quote Returns Weird Hash Keys

The module uses `$;` (subscript separator) as a delimiter in hash keys:

```perl
# Returns keys like: "AAPL price", "AAPL close", "MSFT price", etc.
my %quotes = $quoter->fetch('yahoojson', 'AAPL', 'MSFT');

# To iterate:
foreach my $key (keys %quotes) {
    my ($symbol, $attr) = split(/$;/, $key, 2);
    # $symbol = "AAPL", $attr = "price"
}
```

### 3. MCP Requires Strict JSON-RPC

- **NO extra fields** - LM Studio's Zod validation rejects unknown keys (e.g., `timestamp`)
- **Must implement both POST and GET** for `/mcp` endpoint (GET for SSE fallback)
- **Use standard JSON-RPC 2.0** - responses must have `jsonrpc`, `id`, `result`/`error`

### 4. Cache Returns Full PSGI Response Array

```perl
# Cache stores full [status, headers, body] array
my $cached = FQCache::get($key);
return $cached if $cached;  # Returns array ref!

# To extract JSON from cached response:
my $body = $cached->[2][0];  # body is array ref
my $parsed = decode_json($body);
```

### 5. Currency Conversion Is Tricky

Multiple fallback strategies required:

```perl
# 1. Try AlphaVantage first (needs API key)
# 2. Try Yahoo (fetch "USDUSD" style pair)
# 3. Try Finance::Quote::Currencies module
```

### 6. Python FinanceDatabase module is udated daily via cron in container

See /cron-scripts/ for the scripts, financequote.cron is the cron installed at the container during docker build.
Script update-financedatabase update the FinanceDatabse python module at around midnight.
At a later stage (2 hours later) the sqlite3 db located at /tmp/finance_database.db in the container is refreshed, see import_financedatabse.py, the db is opened with proper locking for concurrent access.

### 7. Finance::Quote methods are case sensitive.

period.

## Adding New Endpoints

### Pattern for REST API

```perl
# 1. Add handler function in FQAPI package
sub handle_newfeature {
    my ($param, $params) = @_;
    # ... logic
    return json_response('success', $data);
}

# 2. Add route in Plack builder
if ($path =~ m{^/api/v1/newfeature/([^/]+)$}) {
    return FQAPI::handle_newfeature($1, \%params);
}
```

### Pattern for MCP Tool

```perl
# 1. Add tool definition in tools/list response
{
    name => 'my_tool',
    description => 'What it does',
    inputSchema => {
        type => 'object',
        properties => {
            param1 => { type => 'string', description => '...' },
        },
        required => ['param1'],
    },
}

# 2. Add handler in tools/call
if ($tool_name eq 'my_tool') {
    my $arg = $tool_args->{param1};
    # ... logic
    return jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
}
```

## Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `FQ_CURRENCY` | Default currency for quotes (e.g., EUR) | Yes |
| `FQ_CACHE_TTL` | Cache duration in seconds (default: 900) | No |
| `FQ_CACHE_ENABLED` | 1 or 0 to enable/disable cache | No |
| `API_AUTH_KEYS` | Comma-separated API keys for auth | No |
| `ALPHAVANTAGE_API_KEY` | AlphaVantage API key (for premium data) | No |
| Other `*_API_KEY` vars | Various provider keys | No |

## Testing and Developing Locally

Local Containers runs at port 3002, app runs on port 3000 inside. 
The developemnt container has mounted as a volume the projects /app folder. Any editing in the app folder does not need rebuild (unless you add modules), if editing the app.psgi a restart is required (make restartlocal) for the changes to work. 
Everytime the container starts it populates the sqlite db, it takes a couple of seconds to be regenerated.
Editing /cron-scripts needs make rebuildlocal.


```bash
# Use make in project root to see all options
	make # see help
	make buildlocal    # Build Local Docker image
	make uplocal       # Start development environment
	make uplocalnotdetached # Start development environment with not detached console
	make downlocal     # Stop local container
	make restartlocal  # Restart local container (needed if editing psgi)
	make logslocal     # View local container logs
	make healthlocal   # Check local container API health
	make cleanlocal   # Stops and removes local container
	make testlocal    # Test local API endpoint (/api/v1/methods)
	make testlocalmethods:  # Test local API endpoint (/api/v1/methods)
	make testlocalquote:    # Test local API endpoint (/api/v1/quote)
	make testlocalinfo:     # Test local API endpoint (/api/v1/info)
	make testlocalcurrency: # Test local API endpoint (/api/v1/currency)
	make testlocalmcp:      # Test local API endpoint (/mcp)

```

## Common Pitfalls

1. **Forgetting to cache** - Always cache expensive operations
2. **Not handling failures** - Check `$result{$sym}` exists before processing
3. **Hardcoding ports** - Container exposes 3001, app runs on 3000 inside
4. **Missing CORS headers** - Always add `Access-Control-Allow-Origin: *`
5. **Perl strict mode** - Declare all variables with `my`, use `use strict; use warnings;`

## Client Libraries

See `libs/` directory for:
- `libs/python/financequote.py`
- `libs/node/financequote.js`
- `libs/go/financequote.go`

These are generated/updated independently - they're not part of the Docker build.

## Release Process

1. Ask user before tag and release unless instructed to wrap up or not to ask anymore in this session.
2. Always update documents like TASKS.md, SPEC.md and README.md before releasing and there are changes or functionality that must be documented.

```bash
# 1. Make changes
git add -A
git commit -m "Description"

# 2. Tag and push
git tag v1.x.x
git push origin main --tags

# 3. Create GitHub release
gh release create v1.x.x --title "v1.x.x" --generate-notes
```

Docker Hub auto-builds from GitHub releases.
