# Python Client for FinanceQuote API

A Python client library for the FinanceQuote REST API.

## Installation

```bash
pip install requests
```

Or install from source:
```bash
pip install .
```

## Quick Start

```python
from financequote import quote, quotes, currency

# Get a single quote
data = quote("AAPL", "http://localhost:3001")
print(f"AAPL: {data['last']}")

# Get multiple quotes
data = quotes(["AAPL", "GOOGL", "MSFT"], "http://localhost:3001")
for symbol, info in data.items():
    print(f"{symbol}: {info['last']}")

# Currency conversion
rate = currency("USD", "EUR", "http://localhost:3001")
print(f"USD to EUR: {rate}")
```

## Using the Client Class

```python
from financequote import FinanceQuoteClient

# Create client (no auth)
client = FinanceQuoteClient("http://localhost:3001")

# Or with authentication
# client = FinanceQuoteClient("http://localhost:3001", "my-api-key")

# Get single quote
apple = client.get_quote("AAPL")
print(f"Apple: ${apple['last']}")

# Get multiple quotes with options
data = client.get_quotes(
    symbols=["AAPL", "GOOGL"],
    method="yahoojson",
    currency="EUR"
)
print(data)

# Get available methods
methods = client.get_methods()
print(f"Methods: {methods[:5]}...")  # First 5

# Currency conversion
rate = client.get_currency("USD", "EUR")
print(f"Rate: {rate}")

# Health check
print(f"Healthy: {client.health_check()}")
```

## API Reference

### `FinanceQuoteClient(url, api_key=None)`

Create a client instance.

- `url`: API base URL (e.g., `http://localhost:3001`)
- `api_key`: Optional API key

### `client.get_quote(symbol, method='yahoojson', currency=None)`

Get a single stock quote.

### `client.get_quotes(symbols, method='yahoojson', currency=None)`

Get multiple quotes.

### `client.get_methods()`

Get list of available quote methods.

### `client.get_currency(from_currency, to_currency)`

Get currency conversion rate.

### `client.health_check()`

Check API health.

## Convenience Functions

```python
# Single quote
quote("AAPL")

# Multiple quotes
quotes(["AAPL", "GOOGL"])

# Currency
currency("USD", "EUR")
```

## Available Quote Methods

- `yahoojson` - Yahoo Finance (default, no API key)
- `alphavantage` - AlphaVantage (requires API key)
- `twelvedata` - Twelve Data (requires API key)
- `financeapi` - FinanceAPI (requires API key)
- And 40+ more...

## Error Handling

```python
from financequote import FinanceQuoteClient

client = FinanceQuoteClient("http://localhost:3001")

try:
    quote = client.get_quote("INVALID_SYMBOL")
except ValueError as e:
    print(f"Error: {e}")
```

## Environment Variables

The client also supports reading from environment:

```python
import os

client = FinanceQuoteClient(
    url=os.getenv("FQ_URL", "http://localhost:3001"),
    api_key=os.getenv("FQ_API_KEY")
)
```