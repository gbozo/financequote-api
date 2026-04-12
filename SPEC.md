# FinanceQuote API Specification

## Project Overview

- **Project name**: FinanceQuote API
- **Type**: REST API Docker service
- **Core functionality**: Wrap the Perl Finance::Quote module (from CPAN) as a RESTful API for fetching stock quotes, currency rates, and financial data from 45+ global sources
- **Target users**: Financial applications, trading systems, portfolio managers, developers needing stock quote data
- **License**: MIT

---

## Architecture

### Container Stack
- **Base Image**: Debian bookworm-slim
- **Perl**: 5.36+ from system packages
- **Web Framework**: Plack (PSGI)
- **Server**: Starman (high-performance PSGI server)
- **Architecture**: REST API with JSON responses

### Directory Structure
```
/usr/local/src/financequote/
├── README.md                   # Project overview (GitHub landing)
├── SPEC.md                     # This specification
├── TASKS.md                    # Task tracking
├── LICENSE                     # MIT License
├── docker/
│   ├── Dockerfile              # Main API container
│   ├── docker-compose.yaml     # Orchestration file
│   ├── .dockerignore           # Docker ignore rules
│   └── .env.example            # Environment variables example
├── api/
│   ├── Makefile               # Build/run commands
│   ├── app/
│   │   ├── bin/
│   │   │   └── app.psgi        # PSGI application
│   │   └── public/
│   │       └── index.html      # Interactive documentation
└── libs/
    ├── README.md               # Client libraries overview
    ├── go/                      # Go client library
    │   ├── financequote.go
    │   └── README.md
    ├── python/                 # Python client library
    │   ├── financequote.py
    │   └── README.md
    └── node/                   # Node.js client library
        ├── financequote.js
        └── README.md
```

---

## API Specification

### Base Endpoint
```
http://localhost:3001/api/v1
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/v1/health` | Health check |
| GET | `/api/v1/methods` | List available quote methods |
| GET | `/api/v1/quote/:symbols` | Fetch stock quotes |
| GET | `/api/v1/currency/:from/:to` | Currency conversion |
| GET | `/api/v1/fetch/:method/:symbols` | Fetch using specific method |

### Query Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `method` | Quote source (yahoojson, alphavantage, etc.) | yahoojson |
| `currency` | Target currency for conversion | — |

### Response Format

**Success:**
```json
{
  "status": "success",
  "data": { ... },
  "timestamp": "2026-04-12T12:00:00Z"
}
```

**Error:**
```json
{
  "status": "error",
  "error": {
    "code": 400,
    "message": "Error description",
    "details": "Additional details"
  },
  "timestamp": "2026-04-12T12:00:00Z"
}
```

---

## Authentication

- **Environment Variable**: `API_AUTH_KEYS` (comma-separated)
- **Header**: `Authorization: Bearer <key>`
- When `API_AUTH_KEYS` is empty/unset, no authentication required

---

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `API_AUTH_KEYS` | Comma-separated API keys | (none) |
| `ALPHAVANTAGE_API_KEY` | AlphaVantage API key | (none) |
| `TWELVEDATA_API_KEY` | Twelve Data API key | (none) |
| `FINANCEAPI_API_KEY` | FinanceAPI API key | (none) |
| `STOCKDATA_API_KEY` | StockData API key | (none) |
| `FIXER_API_KEY` | Fixer.io API key | (none) |
| `OPENEXCHANGE_API_KEY` | OpenExchangeRates key | (none) |
| `CURRENCYFREAKS_API_KEY` | CurrencyFreaks key | (none) |
| `APP_PORT` | Host port mapping | 3001 |
| `FQ_TIMEOUT` | Quote fetch timeout (seconds) | 30 |

---

## Quote Methods

45+ sources including:
- `yahoojson` - Yahoo Finance (default, no key)
- `alphavantage` - AlphaVantage (requires key)
- `twelvedata` - Twelve Data (requires key)
- `financeapi` - FinanceAPI (requires key)
- `asx`, `aex`, `nseindia`, `stooq`, and many more

---

## Dependencies

### System Packages (installed in Docker)
- perl, curl, ca-certificates, libssl3, build-essential
- libnet-ssleay-perl, libio-socket-ssl-perl, libwww-perl
- libtimedate-perl, libhtml-parser-perl, libhtml-tagset-perl
- libtry-tiny-perl, libjson-perl

### Perl Modules (installed via cpanm)
- Plack, Starman, JSON::XS
- Finance::Quote (from CPAN)
- String::Util, HTML::TableExtract, Web::Scraper
- Text::Template, Date::Manip, Time::Piece, Date::Parse

---

## Acceptance Criteria

1. ✅ Docker container builds without errors
2. ✅ Container runs and responds on configured port
3. ✅ `/api/v1/health` returns 200 OK
4. ✅ `/api/v1/methods` returns available quote methods
5. ✅ `/api/v1/quote/AAPL` returns valid JSON with stock data
6. ✅ `/api/v1/currency/USD/EUR` returns exchange rate
7. ✅ Error responses follow consistent JSON format
8. ✅ CORS enabled for frontend integration
9. ✅ Optional API authentication works
10. ✅ Interactive documentation accessible at `/`
11. ✅ Client libraries available for Go, Python, Node.js

---

## Deployment

```bash
# Build and run
docker compose -f docker/docker-compose.yaml up -d --build

# Access API
curl http://localhost:3001/api/v1/health

# View docs
open http://localhost:3001
```