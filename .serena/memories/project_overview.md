# FinanceQuote API - Project Overview

## Purpose
REST API wrapper and MCP server for Perl's Finance::Quote library (45+ financial data sources) and Python's FinanceDatabase module.

## Tech Stack
- **Perl 5.36+** (Plack/PSGI, Starman HTTP server)
- **Python 3** (FinanceDatabase importer, SQLite DB)
- **SQLite3** (asset database at /tmp/finance_database.db)
- **Docker** (Debian bookworm-slim base)
- **Client libs**: Go, Python, Node.js

## Key Files
- `app/app.psgi` - Main PSGI application (all handlers + routing)
- `app/lib/FQCache.pm` - In-memory hash-based cache
- `app/lib/FQDB.pm` - SQLite database operations via DBI
- `app/lib/FQUtils.pm` - Utilities, JSON helpers, OpenAPI generator
- `docker/Dockerfile` - Container build
- `cron-scripts/` - Daily FinanceDatabase update + import

## Architecture
Starman(3000) -> Plack::Builder -> FQAPI handlers -> Finance::Quote / FQDB
Single-file PSGI app with inline package FQAPI. No test framework. No linter config.

## Ports
- Production: 3001 (host) -> 3000 (container)
- Local dev: 3002 (host) -> 3000 (container)
