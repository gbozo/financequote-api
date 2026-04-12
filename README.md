# FinanceQuote API

<p align="center">
  <img src="https://img.shields.io/badge/Perl-5.36+-39459f?style=flat&logo=perl&logoColor=white" alt="Perl">
  <img src="https://img.shields.io/badge/Docker-Ready-2496ed?style=flat&logo=docker&logoColor=white">
  <img src="https://img.shields.io/badge/REST-API-green?style=flat">
  <img src="https://img.shields.io/badge/License-MIT-yellowgreen?style=flat">
</p>

> 📈 A production-ready REST API wrapper for the Perl Finance::Quote library — fetch stock quotes, currency rates, and financial data from 45+ global sources with a single HTTP request.

Universal financial data API - stocks, forex, crypto via 45+ providers - Docker Compose build and container.

Made with love and patience, your friend George.

## ✨ Features

- 🚀 **45+ Data Sources** — Yahoo Finance, AlphaVantage, Twelve Data, European exchanges, and more
- 🌍 **Global Markets** — US, Europe, Asia, Australia, India, and more
- 💱 **Currency Conversion** — Real-time exchange rates from multiple providers
- 🔐 **Optional API Key Authentication** — Secure your API with Bearer token auth
- 🐳 **Docker-Ready** — Single command to spin up the entire stack
- 📚 **Interactive Documentation** — Built-in API explorer and tester
- 🌐 **Language Libraries** — Go, Python, and Node.js client libraries included

## 🎯 Quick Start

### ⚡ One-Command Start (Recommended)

```bash
# Just run this - pulls image from GitHub Container Registry
docker compose -f docker-compose.yaml up -d

# Access the API
curl http://localhost:3001/api/v1/health
```

### 🛠️ From Source (Development)

```bash
# Clone the repo
git clone https://github.com/gbozo/financequote-api.git
cd financequote-api

# Build and run
docker compose -f docker/docker-compose.yaml up -d --build
```

### 2. Use the API

```bash
# Get a stock quote
curl "http://localhost:3001/api/v1/quote/AAPL"

# Get multiple quotes
curl "http://localhost:3001/api/v1/quote/AAPL,GOOGL,MSFT"

# List all available methods
curl "http://localhost:3001/api/v1/methods"

# Currency conversion
curl "http://localhost:3001/api/v1/currency/USD/EUR"
```

### 3. Open Interactive Docs

Visit **http://localhost:3001** in your browser for:
- Complete API documentation
- Interactive API tester
- Code examples in curl, Python, Go, and JavaScript

## 📡 API Endpoints

| Endpoint | Description | Example |
|----------|-------------|---------|
| `GET /api/v1/quote/:symbols` | Fetch stock quotes | `/api/v1/quote/AAPL,MSFT` |
| `GET /api/v1/currency/:from/:to` | Currency conversion | `/api/v1/currency/USD/EUR` |
| `GET /api/v1/methods` | List available sources | — |
| `GET /api/v1/fetch/:method/:symbols` | Use specific source | `/api/v1/fetch/yahoojson/AAPL` |
| `GET /api/v1/health` | Health check | — |

### Query Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `method` | Quote source (yahoojson, alphavantage, etc.) | yahoojson |
| `currency` | Target currency for conversion | — |

## 📦 Available Quote Methods

| Method | Description | API Key Required |
|--------|-------------|------------------|
| `yahoojson` | Yahoo Finance (JSON) | ❌ No |
| `alphavantage` | Alpha Vantage | ✅ Yes |
| `twelvedata` | Twelve Data | ✅ Yes |
| `financeapi` | FinanceAPI | ✅ Yes |
| `asx` | Australian Securities Exchange | ❌ No |
| `aex` | Amsterdam Exchange | ❌ No |
| `nseindia` | National Stock Exchange India | ❌ No |
| `stooq` | Stooq (Poland) | ❌ No |
| + 40 more... | | |

## 🔐 Authentication

Enable API authentication by setting `API_AUTH_KEYS`:

```bash
# .env file
API_AUTH_KEYS=key1,key2,key3
```

```bash
# Using authenticated requests
curl -H "Authorization: Bearer key1" "http://localhost:3001/api/v1/quote/AAPL"
```

## 🛠️ Configuration

### Environment Variables

```bash
# API Authentication (comma-separated keys)
API_AUTH_KEYS=

# Stock Quote API Keys
ALPHAVANTAGE_API_KEY=
TWELVEDATA_API_KEY=
FINANCEAPI_API_KEY=
STOCKDATA_API_KEY=

# Currency API Keys
FIXER_API_KEY=
OPENEXCHANGE_API_KEY=
CURRENCYFREAKS_API_KEY=

# App Settings
APP_PORT=3001
FQ_TIMEOUT=30
```

## 📚 Client Libraries

Ready-to-use libraries for your favorite language:

### Go
```go
client := financequote.NewClient("http://localhost:3001", "api-key")
quote, _ := client.GetQuote("AAPL", nil)
```

### Python
```python
client = FinanceQuoteClient("http://localhost:3001", "api-key")
quote = client.get_quote("AAPL")
```

### Node.js
```javascript
const client = new FinanceQuoteClient('http://localhost:3001', 'api-key');
const quote = await client.getQuote('AAPL');
```

→ [View all libraries](libs/)

## 🐳 Docker Options

### Production (uses released image)
```bash
# Pull latest release and run
docker compose -f docker-compose.yaml up -d

# Or with custom port
APP_PORT=7000 docker compose -f docker-compose.yaml up -d
```

### Development (builds from source)
```bash
docker compose -f docker/docker-compose.yaml up -d --build
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

<div align="center">

**⭐ If this project helped you, please give it a star!**

Built with ❤️ using Perl, Plack, and Docker

</div>