# FinanceQuote API - Task List

## v1.70 - Code Review & Refactoring

Comprehensive code review with 22 improvements across security, bugs, architecture, code quality, reliability, and polish.

### Critical - Security

- [x] **#1 SQL injection in FQDB.pm** - Added `%VALID_TABLES` whitelist and `_validate_table()` function. All table names are now validated before use in SQL. Also converted `search()` primary_exchanges to use parameterized `IN (?)` placeholders instead of string interpolation.

### High - Bugs

- [x] **#2 Static image route double-slash** - FQRouter captures filename without leading slash, preventing `/app/public//images/...` paths.
- [x] **#3 Makefile `uplocalnotdetached` ran detached** - Removed `-d` flag from the target so it actually runs in foreground.
- [x] **#4 MCP cached data access pattern** - Removed `_extract_mcp_data` entirely. MCP now uses standard PSGI cache format `$cached->[2][0]` consistently (was using broken `$cached->[0][3][0]`).
- [x] **#5 Python client `get_currency()` wrong response path** - Fixed to read `data["rate"]` directly instead of nested `data["USDEUR"]["rate"]`.
- [x] **#6 `stats()` total includes itself** - Now accumulates total in a separate variable before adding to the result hash.

### High - Architecture

- [x] **#7 Extract routes to FQRouter.pm** - New module handles all HTTP plumbing: route dispatch, auth checking, CORS headers, static file serving, query string parsing. `app.psgi` now contains only handler business logic. Plack builder is 4 lines.
- [x] **#8 MCP handler duplicates REST logic** - Extracted shared `_fetch_quotes_data()`, `_fetch_info_data()`, `_fetch_currency_data()` functions used by both REST handlers and MCP tools/call. MCP now uses same cache keys as REST (no duplicate caching). MCP handler split into `_mcp_tool_definitions()` and `_handle_mcp_tool_call()`.
- [x] **#9 Unbounded cache growth** - Added `$max_entries` (default 10000) with LRU eviction to FQCache. `_evict()` first removes expired entries, then evicts oldest 10% by access time if still full. Configurable via `FQ_CACHE_MAX_ENTRIES` env var.

### Medium - Code Quality

- [x] **#10 `_normalize_method()` rebuilt map every call** - `%METHOD_MAP` now built once at startup in `app.psgi`.
- [x] **#11 Version hardcoded in 3+ places** - Single `$FQUtils::VERSION` constant referenced by health, MCP initialize, and OpenAPI spec.
- [x] **#12 JSON via string concatenation** - `jsonrpc_response()`, `jsonrpc_error()`, `json_error_response()` in FQUtils now build Perl hashes and call `encode_json()` instead of manual string building.
- [x] **#13 `handle_info` used `split(/$;/)` instead of `index()`** - Changed to `index()` + `substr()` as recommended to avoid encoding issues with the subscript separator.
- [x] **#14 Repetitive API key config** - Replaced 7 if-blocks with data-driven `%API_KEY_MODULES` hash and loop.
- [x] **#15 `sanitize_input()` unused** - Kept in FQUtils for use by FQDB and future input validation.

### Medium - Reliability

- [x] **#16 Silent DB errors** - Changed `PrintError => 1` in FQDB (was 0), so DB errors are no longer silently swallowed.
- [x] **#17 No DB connection recovery** - `get_connection()` now pings with `SELECT 1` and reconnects if the connection is stale (handles SQLite file replacement by cron).
- [x] **#18 Auth blocks health endpoint** - FQRouter's `_is_public_path()` exempts `/api/v1/health` and static asset paths from API key authentication.

### Low - Polish

- [x] **#19 Go client unsafe type assertions** - All type assertions now use comma-ok pattern with proper error handling.
- [x] **#20 Python import shadow in `import_financedatabase.py`** - Renamed `fd` variable to `lock_fh` in `acquire_lock()`/`release_lock()` to avoid shadowing the `financedatabase` module import.
- [x] **#21 Node.js and Go client currency response path** - Both now read `data.rate` / `data["rate"]` directly matching actual API response format.
- [x] **#22 FQCache `configure()` odd conditional** - Fixed to clean `if (defined $env_ttl && $env_ttl =~ /^\d+$/)` check.

### Documentation

- [x] **AGENTS.md revised** - Updated architecture diagram (added FQRouter layer), module responsibilities, all 10 gotchas revised (added whitelisting, VERSION, auth exemption), added `FQ_CACHE_MAX_ENTRIES` env var, updated adding-new-endpoints patterns (FQRouter route + shared `_fetch_*_data()`), updated common pitfalls (8 items), fixed testing commands, corrected port numbers.
- [x] **TASKS.md updated** - This file; all 22 items documented with implementation details.
- [x] **Makefile targets** - Added missing `testlocalspec` target and `testlocal` (runs all tests).

### Files Changed

| File | Change |
|------|--------|
| `app/lib/FQDB.pm` | Table whitelist, parameterized queries, reconnect, PrintError |
| `app/lib/FQCache.pm` | LRU eviction, max entries, configure() fix |
| `app/lib/FQUtils.pm` | VERSION constant, encode_json() for all JSON, kept sanitize_input |
| `app/lib/FQRouter.pm` | **NEW** - routing, auth, CORS, static files extracted from app.psgi |
| `app/app.psgi` | Handlers only, shared _fetch_*_data(), METHOD_MAP at startup, data-driven API keys |
| `Makefile` | Fixed uplocalnotdetached, added testlocalspec, testlocal |
| `libs/python/financequote.py` | Fixed get_currency() response path |
| `libs/go/financequote.go` | Safe type assertions, fixed GetCurrency() |
| `libs/node/financequote.js` | Fixed getCurrency() response path |
| `cron-scripts/import_financedatabase.py` | Fixed fd variable shadow |
| `AGENTS.md` | Full revision reflecting new architecture |

---

## v1.71 - MCP Enrichment

Comprehensive MCP protocol enrichment: composite tools, discovery tools, resources, enriched descriptions, and protocol improvements. Grew from 8 tools to 13 tools + 3 resources.

### Composite Tools (New)

- [x] **`analyze_symbol`** - All-in-one tool: auto-resolves name/ticker via DB lookup/search, fetches live quote + detailed info in a single call. Eliminates multi-step lookup-then-quote workflows.
- [x] **`get_portfolio`** - Batch quotes for multiple symbols in one call. Returns per-symbol results with method and currency info. Replaces repeated get_quote calls.
- [x] **`compare_symbols`** - Side-by-side comparison of 2+ symbols: price, PE, yield, market cap, sector. Enriches with DB data (sector, industry, country) when available.
- [x] ~~**`convert_amount`**~~ - Removed: Finance::Quote already returns quotes in the requested currency via `get_quote(currency)`, and `get_currency` provides the rate for agents to multiply. An amount conversion tool adds no unique capability.

### Discovery Tools (New)

- [x] **`get_filter_options`** - Exposes valid filter values per asset type (sectors, countries, exchanges, market_caps). Agents can discover what values to pass to filter_assets.
- [x] **`get_asset_types`** - Lists available asset types with descriptions and row counts from the database. Helps agents understand what data is available.

### Description Enrichment

- [x] **All 13 tool descriptions enriched** - Every tool now includes: example inputs, output field names, guidance on when to use which tool, cross-references to related tools (e.g., filter_assets says "Use get_filter_options first").
- [x] **Error messages include actionable hints** - Required field errors now show examples of valid values.

### Protocol Improvements

- [x] **`notifications/initialized` handled** - Returns empty 200 instead of JSON-RPC error. Required by MCP spec.
- [x] **Resources capability** - `resources/list` and `resources/read` with 3 resources:
  - `financequote://methods` - all available quote methods
  - `financequote://asset-types` - asset types with descriptions and row counts
  - `financequote://server-info` - version, cache status, capabilities
- [x] **`initialize` advertises resources** - Response now includes `resources` capability alongside `tools`.
- [x] **Unknown method error improved** - Lists all supported methods for quick recovery.

### MCP Prompts (New)

- [x] **`analyze_stock`** - Pre-built prompt for comprehensive stock analysis. Instructs the agent to use `analyze_symbol` and present structured output: company overview, current price, valuation, income, 52-week performance, and key takeaway.
- [x] **`compare_investments`** - Side-by-side investment comparison prompt. Uses `compare_symbols` and presents comparison table, valuation analysis, size/sector comparison, and summary.
- [x] **`market_screener`** - Market screening prompt. Uses `get_filter_options` + `filter_assets` + `get_portfolio` to find and price stocks matching sector/country/market cap criteria.
- [x] **`currency_check`** - Quick forex lookup prompt. Uses `get_currency` and presents rate with 1/10/100/1000 conversion examples.

### MCP Module Extraction

- [x] **FQMCP.pm** - Extracted all MCP logic from app.psgi into dedicated `app/lib/FQMCP.pm` module (~790 lines). Includes JSON-RPC dispatch, tool definitions/handlers, resource definitions/reader, prompt definitions/handler. Configured at startup via `FQMCP::configure()` with references to shared `_fetch_*_data()` functions. app.psgi reduced from 1164 to 444 lines.
- [x] **app.psgi** - `handle_mcp()` now delegates to `FQMCP::handle($body)`. Developers add REST handlers in app.psgi, MCP tools/resources/prompts in FQMCP.pm.

### Documentation Updates

- [x] **README.md** - Updated MCP section with all 13 tools in categorized table, 3 resources, 4 prompts, new curl examples, Claude Desktop and OpenCode/Cursor config examples.
- [x] **AGENTS.md** - Architecture diagram updated with FQMCP module. Module responsibilities section includes FQMCP. MCP tool/prompt patterns reference FQMCP.pm.
- [x] **TASKS.md** - This section documenting all MCP enrichments.

### Files Changed

| File | Change |
|------|--------|
| `app/app.psgi` | 6 new tools, 3 resources, enriched descriptions, notifications/initialized, resources/list+read |
| `AGENTS.md` | MCP tool guidelines, resources section, tool categories table |
| `TASKS.md` | v1.71 section with all MCP enrichment details |
| `README.md` | Updated MCP tools table (14), resources table (3), new curl examples, multi-client configs |

---

## v1.72 - FinanceDatabase Per-Type Schema Fix

Fixed critical data import issue: the import script used a one-size-fits-all equities schema for all 7 asset types, silently dropping type-specific columns. Each upstream FinanceDatabase asset type has a different schema.

### Data Loss Fixed

| Asset Type | Columns Previously DROPPED | Now Correctly Imported |
|---|---|---|
| **Currencies** | `base_currency`, `quote_currency` | symbol, name, summary, exchange, base_currency, quote_currency |
| **Cryptos** | `cryptocurrency` | symbol, name, currency, summary, exchange, cryptocurrency |
| **ETFs** | `category_group`, `category`, `family` | symbol, name, currency, summary, category_group, category, family, exchange, market |
| **Funds** | `category_group`, `category`, `family` | symbol, name, currency, summary, category_group, category, family, exchange, market |
| **Indices** | `category_group`, `category` | symbol, name, currency, summary, category_group, category, exchange, market |
| **Moneymarkets** | `family` | symbol, name, currency, summary, family |
| **Equities** | *(none - was already correct)* | symbol, name, currency, sector, industry_group, industry, exchange, market, country, state, city, zipcode, website, market_cap, isin, cusip, figi, composite_figi, shareclass_figi, summary |

### Import Script Rewrite (`import_financedatabase.py`)

- [x] **Per-type `TABLE_SCHEMAS`** - Each asset type now has its own column list matching upstream FinanceDatabase source code.
- [x] **Per-type `TABLE_INDEXES`** - Indexes on filterable/searchable columns per type (not one-size-fits-all).
- [x] **Drop+recreate tables** on each import to handle schema changes cleanly.
- [x] **NaN handling** - Explicit NaN-to-None conversion (was silently passing through).
- [x] **Schema version metadata** - `schema_version: 2` tracked in metadata table.
- [x] **Logging improvements** - Reports missing/extra columns vs schema for each type.

### Type-Aware Query Layer (`FQDB.pm`)

- [x] **`%TABLE_COLUMNS`** - Per-type column definitions matching import schemas.
- [x] **`%SEARCH_COLUMNS`** - Type-appropriate search targets:
  - equities: symbol, name, isin
  - etfs/funds: symbol, name, category, family
  - currencies: symbol, name, base_currency, quote_currency
  - cryptos: symbol, name, cryptocurrency
- [x] **`%SEARCH_RESULT_COLUMNS`** - Type-appropriate result fields (e.g., currencies return base_currency/quote_currency, not sector/country).
- [x] **`%FILTER_COLUMNS`** - Type-appropriate filter parameters:
  - equities: sector, country, exchange, market_cap, industry, industry_group, currency, market
  - etfs/funds: category_group, category, family, exchange, currency, market
  - currencies: base_currency, quote_currency, exchange
  - cryptos: cryptocurrency, currency, exchange
  - moneymarkets: currency, family
- [x] **`filter()` dynamic dispatch** - Accepts any filter param valid for the given type, rejects invalid ones.
- [x] **`get_filter_options()` per-type** - Returns only the filter columns that exist for the given type.
- [x] **`asset_types()` includes filters** - Each type now reports its available filter columns.
- [x] **`get_columns()` / `get_filter_columns()`** - New accessor functions for type introspection.

### MCP Tool Updates (`FQMCP.pm`)

- [x] **`filter_assets` tool** - Now accepts ALL type-specific filter params (category_group, category, family, base_currency, quote_currency, cryptocurrency) and forwards them dynamically to FQDB.
- [x] **`filter_assets` description** - Documents which filters apply to which types.
- [x] **`get_filter_options` description** - Explains per-type filter behavior with examples.
- [x] **`search_assets` description** - Documents type-aware search columns.
- [x] **`get_asset_types` description** - Notes that filter columns are included per type.
- [x] **`lookup_symbol` description** - Notes type-specific return fields.
- [x] **`market_screener` prompt** - Updated to guide agents through type-aware filtering.

### Documentation

- [x] **AGENTS.md** - Updated FQDB module description, gotcha #6 (per-type schemas), gotcha #8 (type-aware queries with all 4 column maps).

### Files Changed

| File | Change |
|------|--------|
| `cron-scripts/import_financedatabase.py` | Complete rewrite: per-type TABLE_SCHEMAS, TABLE_INDEXES, drop+recreate, NaN handling |
| `app/lib/FQDB.pm` | Type-aware queries: TABLE_COLUMNS, SEARCH_COLUMNS, SEARCH_RESULT_COLUMNS, FILTER_COLUMNS |
| `app/lib/FQMCP.pm` | Updated filter_assets to accept all type-specific params, enriched descriptions |
| `AGENTS.md` | Per-type schema docs, type-aware query docs |

---

## v1.74 - SVG Stock Card Generator

Added `FQChart.pm` module for generating self-contained SVG stock card images in three sizes. Available via REST endpoint and MCP tool.

### FQChart.pm Module

New SVG generator with three card sizes:
- [x] **Small (400x250)** - Symbol badge, price + change (green/red color), sparkline with gradient fill, date range footer
- [x] **Medium (600x400)** - Full line chart with Y-axis/X-axis labels, grid lines, volume bars, 52-week range bar with position marker, stats row (High/Low/Volume/Open)
- [x] **Large (800x500)** - Fundamentals row (P/E, EPS, Div Yield, Mkt Cap), company info row (Sector, Industry, Country, Exchange), FinanceQuote API watermark

Dark theme color palette: `#1a1a2e` background, `#00c853` green, `#ff1744` red, `#00bcd4` accent.

### REST Endpoint

- [x] `GET /api/v1/chart/{symbol}` - SVG stock card generation
  - Parameters: `size` (small/medium/large), `method`, `currency`, `days`, `format` (svg/json/html)
  - Fetches live info + history + DB enrichment
  - Three output formats: raw SVG, base64 JSON, embedded HTML page

### MCP Tool

- [x] `get_stock_card` - Returns base64-encoded SVG + data URI for AI agents (16 tools total)

### Files Changed

| File | Changes |
|------|---------|
| `app/lib/FQChart.pm` | New module - SVG stock card generator |
| `app/app.psgi` | `handle_chart()` handler, route registration |
| `app/lib/FQRouter.pm` | Route: `/api/v1/chart/{symbol}` |
| `app/lib/FQMCP.pm` | `get_stock_card` tool definition + handler |
| `app/lib/FQUtils.pm` | VERSION 1.74 |
| `AGENTS.md` | FQChart module docs, Charts MCP category |
| `README.md` | Chart endpoint, 16 MCP tools |

---

## v1.73 - SQLite Cache + Quote History

Replaced in-memory cache with SQLite-backed `quotes_cache` table and added permanent `quotes_history` table for daily quote snapshots with searchable columns. Persistent storage via Docker volumes replaces tmpfs.

### SQLite Cache (`FQCache.pm`)

- [x] **Complete rewrite** - FQCache now uses SQLite `quotes_cache` table instead of in-memory hash.
  - Schema: `cache_key TEXT PRIMARY KEY, status INTEGER, headers TEXT (JSON), body TEXT, expires_at INTEGER, created_at INTEGER`
  - Index on `expires_at` for efficient cleanup
  - `_get_dbh()` with reconnect-on-failure, WAL mode, busy_timeout=30s
  - `get()` deletes expired entries on access
  - `set()` validates PSGI array structure, stores status/headers(JSON)/body separately
  - `purge_expired()` for cron-based cleanup
  - `stats()` returns `{enabled, ttl, entries, expired, backend:'sqlite'}`

### Quote History (`FQDB.pm`)

- [x] **`quotes_history` table** - Permanent per-symbol per-day records with searchable columns:
  - Columns: symbol, date, name, exchange, currency, open, close, high, low, last, volume, change, p_change, pe, eps, div, yield, cap, year_high, year_low, day_range, year_range, method, fetched_at
  - `UNIQUE(symbol, date, method)` constraint for deduplication
  - Indexes: idx_history_symbol, idx_history_date, idx_history_symbol_date
- [x] **`init_history_table()`** - Creates table and indexes at startup
- [x] **`record_quote($symbol, $data, $method)`** - INSERT OR REPLACE single record
- [x] **`record_quotes($quotes_hash, $method)`** - Batch record from quote hash (skips non-success)
- [x] **`get_history(%opts)`** - Query by symbol, from, to, limit, method
- [x] **`get_history_symbols()`** - Returns symbols with day counts and date ranges
- [x] **`history_stats()`** - Total records, symbols, date range

### Automatic Recording (`app.psgi`)

- [x] **`_fetch_quotes_data()`** now calls `FQDB::record_quotes()` after every fetch
- [x] **`_fetch_info_data()`** now calls `FQDB::record_quote()` for successful fetches
- [x] Both wrapped in `eval {}` so recording failures never break the request

### REST API Endpoints

- [x] **`GET /api/v1/history/{symbol}`** - Query historical data with optional from/to/limit/method params
- [x] **`GET /api/v1/history`** - Overview of all tracked symbols with date ranges and record counts

### MCP Tools (`FQMCP.pm`)

- [x] **`get_price_history`** - Query historical quote data by symbol with date range and limit
- [x] **`get_history_overview`** - Overview of all symbols with historical data

### Container Changes

- [x] **Persistent storage** - Docker volumes replace tmpfs for SQLite database
  - `fq-data:/data` in docker-compose.yaml (production)
  - `fq-data-local:/data` in docker-compose.local.yaml (development)
- [x] **Conditional first-run import** - Dockerfile CMD checks if DB exists/has data before running import. Subsequent starts skip the import.
- [x] **Default DB path changed** - `/data/finance_database.db` (was `/tmp/finance_database.db`)
- [x] **`FQ_DB_PATH` env var standardized** - All components use `FQ_DB_PATH` (was inconsistent `FINANCE_DB_PATH`)
- [x] **`cleanup-cache` cron job** - Purges expired `quotes_cache` entries every hour
- [x] **`sqlite3` CLI added** - Installed in container for cache cleanup script

### Files Changed

| File | Change |
|------|--------|
| `app/lib/FQCache.pm` | Complete rewrite: SQLite backend, quotes_cache table |
| `app/lib/FQDB.pm` | Added quotes_history table, record/query functions |
| `app/app.psgi` | Auto-recording in fetch functions, history handlers, FQ_DB_PATH |
| `app/lib/FQRouter.pm` | Added /api/v1/history routes |
| `app/lib/FQMCP.pm` | Added get_price_history and get_history_overview tools |
| `docker/Dockerfile` | Conditional import, /data dir, sqlite3 CLI, chmod scripts |
| `docker-compose.yaml` | Persistent volume, FQ_DB_PATH env, removed tmpfs |
| `docker-compose.local.yaml` | Persistent volume, FQ_DB_PATH env, removed tmpfs |
| `cron-scripts/cleanup-cache` | **NEW** - hourly cache expiry cleanup |
| `cron-scripts/financequote.cron` | Added cleanup-cache hourly job |
| `cron-scripts/import_financedatabase.py` | FQ_DB_PATH env var, /data default |
| `AGENTS.md` | Updated cache, history, cron, env vars, MCP tools docs |

---

## Previous Tasks (v1.0 - v1.69)

### Core Infrastructure
- [x] Create SPEC.md with detailed API specification
- [x] Create Dockerfile for Perl PSGI API
- [x] Create docker-compose.yaml
- [x] Create .dockerignore file
- [x] Create Makefile for build commands
- [x] Create .env.example for environment variables

### API Implementation
- [x] Create PSGI entry point (app.psgi)
- [x] Implement /api/v1/health endpoint
- [x] Implement /api/v1/methods endpoint
- [x] Implement /api/v1/quote/:symbols endpoint
- [x] Implement /api/v1/currency/:from/:to endpoint
- [x] Implement /api/v1/fetch/:method/:symbols endpoint

### Finance::Quote Integration
- [x] Install Finance::Quote from CPAN (latest version)
- [x] Integrate Finance::Quote module
- [x] Configure quote fetchers (yahoojson, etc.)
- [x] Configure currency conversion

### Documentation
- [x] Interactive API documentation at `/`
- [x] Dynamic URL detection in docs
- [x] Live methods table loaded from API
- [x] Code examples for curl, Python, Go, JS

### Security
- [x] API key authentication via API_AUTH_KEYS
- [x] Bearer token support
- [x] Environment variable for API keys

### Client Libraries
- [x] Go client library (libs/go/)
- [x] Python client library (libs/python/)
- [x] Node.js client library (libs/node/)
- [x] README for each library

### Polish
- [x] JSON response ordering fixed
- [x] ISO timestamp format
- [x] CORS enabled
- [x] GitHub-ready README.md
