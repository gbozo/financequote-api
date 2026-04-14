# Style and Conventions

## Perl
- `use strict; use warnings;` always
- Inline package (`package FQAPI`) inside app.psgi
- Sub-based routing with regex matching in Plack builder
- FQ utility functions imported as wrapper subs in FQAPI
- Cache key format: `prefix:part1:part2:...`
- Response format: `[status_code, [headers], [json_body]]` (PSGI triplet)
- JSON response envelope: `{status, data, timestamp}`
- Error envelope: `{status: "error", error: {code, message, details}, timestamp}`
- MCP uses JSON-RPC 2.0 with strict compliance

## Python
- Standard logging, type hints in client lib
- FinanceDatabase importer uses file locking (fcntl)
- SQLite WAL mode for concurrent access

## Naming
- Perl subs: snake_case (handle_quote, build_cache_key)
- Perl packages: CamelCase (FQCache, FQDB, FQUtils)
- Client libs: language-idiomatic naming

## No automated testing, linting, or formatting tools configured.
