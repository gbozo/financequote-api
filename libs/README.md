# FinanceQuote API Client Libraries

Language-specific client libraries for consuming the FinanceQuote REST API.

## Overview

These libraries provide simple, native interfaces to the FinanceQuote API in your preferred language.

## Supported Languages

| Language | Directory | Installation |
|----------|-----------|--------------|
| **Go** | `go/` | `go get` |
| **Python** | `python/` | `pip install requests` |
| **Node.js** | `node/` | `npm install` |

## Quick Comparison

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

## Common Features

All clients support:

- ✅ Get single/multiple stock quotes
- ✅ List available quote methods
- ✅ Currency conversion
- ✅ API health check
- ✅ Optional API key authentication

## Usage

1. **Start the API**: `docker compose -f docker/docker-compose.yaml up -d`
2. **Choose your language**: Go / Python / Node.js
3. **Copy the library** into your project
4. **Start coding**:

```go
// Go
quote, _ := client.GetQuote("AAPL", nil)
```

```python
# Python
quote = client.get_quote("AAPL")
```

```javascript
// Node.js
const quote = await client.getQuote('AAPL');
```

## Documentation

See individual README files for detailed API reference:
- [Go README](go/README.md)
- [Python README](python/README.md)
- [Node.js README](node/README.md)