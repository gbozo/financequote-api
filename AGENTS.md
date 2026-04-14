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
| `/app/app.psgi` | Handler business logic only (FQAPI package) |
| `/app/lib/FQRouter.pm` | HTTP routing, auth, CORS, static file serving |
| `/app/lib/FQMCP.pm` | MCP JSON-RPC dispatch, tools, resources, prompts |
| `/app/lib/FQCache.pm` | In-memory LRU cache with TTL and max size |
| `/app/lib/FQDB.pm` | SQLite database operations (table-whitelisted) |
| `/app/lib/FQUtils.pm` | Utilities, JSON helpers, OpenAPI generator, VERSION |
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
│  Plack::Builder │  ← PSGI entry point (4 lines in app.psgi)
└────────┬────────┘
         │
┌────────▼────────┐
│    FQRouter     │  ← Route dispatch, auth, CORS, static files, query parsing
└────────┬────────┘
         │
┌────────▼────────┐
│  FQAPI package  │  ← REST handler business logic (handle_quote, handle_info, etc.)
└────────┬────────┘
         │
    ┌────┼────────┐
    │    │        │
┌───▼──┐│┌───────▼──────┐
│Finance│││    FQMCP     │  ← MCP JSON-RPC: tools, resources, prompts
│::Quote│││              │
└───────┘│└──────┬───────┘
    ┌────▼────┐  │
    │  FQDB   │◄─┘  ← SQLite FinanceDatabase
    └─────────┘
```

### Module Responsibilities

- **app.psgi**: Contains the `FQAPI` package with REST handler functions and shared `_fetch_*_data()` core logic. Developers add new REST features here. The Plack builder at the bottom just wires `FQRouter::dispatch()`.
- **FQRouter.pm**: All HTTP plumbing - route regex matching, auth checking, CORS headers, static file serving, query string parsing. Developers should rarely need to touch this.
- **FQMCP.pm**: All MCP (Model Context Protocol) logic - JSON-RPC dispatch, tool definitions/handlers, resource definitions/reader, prompt definitions/handler. Configured at startup with references to shared `_fetch_*_data()` functions from FQAPI.
- **FQCache.pm**: In-memory key/value cache with configurable TTL, max entry limit, and LRU eviction. Stores full PSGI response arrays.
- **FQDB.pm**: SQLite interface for FinanceDatabase data. Uses table name whitelisting to prevent SQL injection.
- **FQUtils.pm**: Shared utilities - JSON response builders, `jsonrpc_response`/`jsonrpc_error`, OpenAPI spec generator, `sanitize_input()`, and the single `$VERSION` constant.

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

### 2. Finance::Quote Uses `$;` Subscript Separator

The module uses `$;` (chr(28), NOT chr(3)) as a delimiter in hash keys. **Always use `index()` + `substr()`** to parse these keys - never `split()` which can have encoding issues:

```perl
# Returns keys like: "AAPL\x1Chigh", "AAPL\x1Cclose", etc.
my %quotes = $quoter->fetch('YahooJSON', 'AAPL', 'MSFT');

# CORRECT - use index() not split():
foreach my $key (keys %quotes) {
    my $sep = $;;  # chr(28)
    my $pos = index($key, $sep);
    next if $pos < 0;
    my $symbol = substr($key, 0, $pos);
    my $attr = substr($key, $pos + 1);
    # $symbol = "AAPL", $attr = "high"
}
```

### 3. MCP Requires Strict JSON-RPC

- **NO extra fields** - LM Studio's Zod validation rejects unknown keys (e.g., `timestamp`)
- **Must implement both POST and GET** for `/mcp` endpoint (GET for SSE fallback)
- **Use `/mcp/sse` for explicit SSE endpoint**
- **Use standard JSON-RPC 2.0** - responses must have `jsonrpc`, `id`, `result`/`error`
- **Use `FQUtils::jsonrpc_response()` and `FQUtils::jsonrpc_error()`** - these produce correct JSON via `encode_json()`, not string concatenation

### 4. Cache Returns Full PSGI Response Array

```perl
# Cache stores full [status, headers, body] array
my $cached = FQCache::get($key);
return $cached if $cached;  # Returns array ref!

# To extract JSON from cached response:
my $body = $cached->[2][0];  # body is array of strings
my $parsed = decode_json($body);
```

### 5. Currency Conversion Is Tricky

Multiple fallback strategies are implemented in `_fetch_currency_data()`:

```perl
# 1. Try AlphaVantage first (needs API key)
# 2. Try Yahoo (fetch "FROMUSD" style pair)
# 3. Try Finance::Quote::Currencies module
```

Both REST handler (`handle_currency`) and MCP tool (`get_currency`) call the same `_fetch_currency_data()` to avoid logic duplication.

### 6. Python FinanceDatabase module is updated daily via cron in container

See `/cron-scripts/` for the scripts. `financequote.cron` is installed in the container during docker build.
- `update-financedatabase` updates the FinanceDatabase python module at around midnight
- 2 hours later, `import_financedatabase.py` refreshes the SQLite DB at `/tmp/finance_database.db` with proper file locking for concurrent access

### 7. Methods Are Case Insensitive

The `%METHOD_MAP` hash (built once at startup in `app.psgi`) maps lowercase names to their canonical forms (e.g., `yahoojson` → `YahooJSON`). Use `_normalize_method()` for lookups.

### 8. FQDB Table Names Are Whitelisted

FQDB uses a `%VALID_TABLES` whitelist. Any table name not in the whitelist is rejected. When adding new database tables, you must add them to `%VALID_TABLES` in FQDB.pm.

### 9. VERSION Is Centralized

The API version lives in `$FQUtils::VERSION`. All handlers (health, MCP initialize, OpenAPI spec) reference this single constant. Never hardcode version strings.

### 10. Auth Exempts Public Paths

FQRouter exempts `/api/v1/health` and static asset paths from API key authentication. This allows health checks from load balancers and Kubernetes probes without credentials.

## Adding New Endpoints

### Pattern for REST API

```perl
# 1. Add handler function in FQAPI package (app.psgi)
sub handle_newfeature {
    my ($param, $params) = @_;
    # ... business logic
    return json_response('success', $data);
}

# 2. Register route for OpenAPI spec (optional but recommended, in app.psgi)
FQUtils::register_route('/api/v1/newfeature/{id}', 'get', {
    summary => 'Get Feature',
    description => 'Get a specific feature by ID',
    params => [
        { name => 'id', in => 'path', required => 1, type => 'string', description => 'Feature ID' },
    ],
    responses => { '200' => { description => 'Feature data' } },
});

# 3. Add route in FQRouter.pm dispatch()
if ($path =~ m{^/api/v1/newfeature/([^/]+)$}) {
    return FQAPI::handle_newfeature($1, \%params);
}
```

### Pattern for MCP Tool

```perl
# 1. Add tool definition in _tool_definitions() (FQMCP.pm)
{
    name => 'my_tool',
    description => 'What it does. Returns: field1, field2. Example: my_tool({param1: "value"})',
    inputSchema => {
        type => 'object',
        properties => {
            param1 => { type => 'string', description => 'What this param does. Example: "value"' },
        },
        required => ['param1'],
    },
}

# 2. Add handler in _handle_tool_call() (FQMCP.pm)
if ($tool_name eq 'my_tool') {
    my $arg = $tool_args->{param1};
    # ... logic (use $fetch_quotes_fn->(), $fetch_info_fn->(), $fetch_currency_fn->() for data)
    return _jsonrpc_response($id, { content => [{ type => 'text', text => encode_json($result) }] });
}
```

**MCP Tool Description Guidelines:**
- Always include example inputs in the description
- List the output fields the tool returns
- Cross-reference related tools (e.g., "Use get_filter_options first to discover valid values")
- For errors, include actionable hints with examples

### MCP Resources

Resources provide static/semi-static data that agents can read without tool calls:

```perl
# Resources are defined in _mcp_resource_definitions() and handled in handle_mcp()
# Current resources:
#   financequote://methods     - all available quote methods
#   financequote://asset-types - asset types with descriptions and row counts
#   financequote://server-info - version, cache status, capabilities
```

### MCP Tool Categories

| Category | Tools | Purpose |
|----------|-------|---------|
| **Composite** | `analyze_symbol`, `get_portfolio`, `compare_symbols` | Multi-step workflows in one call |
| **Quotes** | `get_quote`, `get_symbol_info`, `get_currency` | Direct Finance::Quote access |
| **Discovery** | `list_methods`, `get_asset_types`, `get_filter_options` | Help agents understand available data |
| **Database** | `search_assets`, `lookup_symbol`, `filter_assets`, `get_db_stats` | FinanceDatabase queries |

### MCP Prompts

Prompts provide pre-built conversation templates that guide agents through common workflows:

```perl
# Prompts are defined in _prompt_definitions() and handled in _handle_prompt_get() in FQMCP.pm
# Current prompts:
#   analyze_stock        - Comprehensive stock analysis with structured output
#   compare_investments  - Side-by-side investment comparison
#   market_screener      - Screen stocks by sector/country/market cap
#   currency_check       - Quick forex rate lookup with conversion examples
```

Each prompt returns a `messages` array with a pre-crafted user message that instructs the LLM which tools to call and how to format the output. The prompts reference the server's default currency (FQ_CURRENCY) so agents know conversion is automatic.

### Shared Logic Between REST and MCP

Core data-fetching functions are shared to avoid duplication:
- `_fetch_quotes_data($method, @symbols)` - fetches and structures quote data
- `_fetch_info_data($method, @symbols)` - fetches detailed symbol info
- `_fetch_currency_data($from, $to)` - handles currency conversion with fallbacks

Both REST handlers and MCP tool handlers call these same functions.
FQMCP receives references to these functions via `FQMCP::configure()` at startup.

## Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `FQ_CURRENCY` | Default currency for quotes (e.g., EUR) | Yes |
| `FQ_CACHE_TTL` | Cache duration in seconds (default: 900) | No |
| `FQ_CACHE_ENABLED` | 1 or 0 to enable/disable cache | No |
| `FQ_CACHE_MAX_ENTRIES` | Max cache entries before LRU eviction (default: 10000) | No |
| `API_AUTH_KEYS` | Comma-separated API keys for auth | No |
| `ALPHAVANTAGE_API_KEY` | AlphaVantage API key (for premium data) | No |
| Other `*_API_KEY` vars | Various provider keys (configured via `%API_KEY_MODULES` loop) | No |

## Testing and Developing Locally

Local container runs at port 3002, app runs on port 3000 inside.
The development container mounts the project's `/app` folder as a volume. Any editing in the app folder does not need a rebuild (unless you add modules). If editing `app.psgi`, a restart is required (`make restartlocal`).
Every time the container starts it populates the SQLite DB; it takes a couple of seconds to regenerate.
Editing `/cron-scripts` needs `make rebuildlocal`.

```bash
# Use make in project root to see all options
make                        # Show help
make buildlocal             # Build Local Docker image
make uplocal                # Start development environment (detached)
make uplocalnotdetached     # Start development environment (foreground, logs visible)
make downlocal              # Stop local container
make restartlocal           # Restart local container (needed if editing psgi)
make logslocal              # View local container logs
make healthlocal            # Check local container API health
make cleanlocal             # Stops and removes local container
make testlocal              # Run all local API tests
make testlocalmethods       # Test /api/v1/methods
make testlocalquote         # Test /api/v1/quote
make testlocalinfo          # Test /api/v1/info
make testlocalcurrency      # Test /api/v1/currency
make testlocalmcp           # Test /mcp
make testlocalspec          # Test /api/v1/spec
```

## Common Pitfalls

1. **Forgetting to cache** - Always cache expensive operations using `FQCache::set($key, $response, $ttl)`
2. **Not handling failures** - Check `$result{$sym}` exists before processing Finance::Quote results
3. **Hardcoding ports** - Container exposes 3002 locally, app runs on 3000 inside
4. **Missing CORS headers** - FQRouter handles CORS globally; don't add custom CORS in handlers
5. **Perl strict mode** - Declare all variables with `my`, use `use strict; use warnings;`
6. **Duplicating logic** - Use shared `_fetch_*_data()` functions; never re-implement quote/currency fetching in MCP handlers
7. **SQL injection** - Never interpolate user input into SQL. FQDB validates table names; use parameterized queries for values
8. **Hardcoding version** - Always use `$FQUtils::VERSION`, never literal version strings

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
