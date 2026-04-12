# Node.js Client for FinanceQuote API

A Node.js client library for the FinanceQuote REST API.

## Installation

```bash
npm install financequote
```

Or link locally:
```bash
npm link /path/to/libs/node
```

## Quick Start

```javascript
const { quote, quotes, currency } = require('financequote');

// Single quote
const data = await quote('AAPL', 'http://localhost:3001');
console.log(`AAPL: ${data.last}`);

// Multiple quotes
const data = await quotes(['AAPL', 'GOOGL', 'MSFT'], 'http://localhost:3001');
for (const [symbol, info] of Object.entries(data)) {
  console.log(`${symbol}: ${info.last}`);
}

// Currency
const rate = await currency('USD', 'EUR', 'http://localhost:3001');
console.log(`USD to EUR: ${rate}`);
```

## Using the Client Class

```javascript
const FinanceQuoteClient = require('financequote').FinanceQuoteClient;

// Create client (no auth)
const client = new FinanceQuoteClient('http://localhost:3001');

// Or with authentication
// const client = new FinanceQuoteClient('http://localhost:3001', 'my-api-key');

// Get single quote
const apple = await client.getQuote('AAPL');
console.log(`Apple: $${apple.last}`);

// Get multiple quotes with options
const data = await client.getQuotes(['AAPL', 'GOOGL'], {
  method: 'yahoojson',
  currency: 'EUR'
});
console.log(data);

// Get available methods
const methods = await client.getMethods();
console.log(`Methods: ${methods.slice(0, 5).join(', ')}...`);

// Currency conversion
const rate = await client.getCurrency('USD', 'EUR');
console.log(`Rate: ${rate}`);

// Health check
console.log(`Healthy: ${await client.healthCheck()}`);
```

## API Reference

### `new FinanceQuoteClient(baseURL, apiKey)`

Create a client instance.

- `baseURL`: API base URL (e.g., `http://localhost:3001`)
- `apiKey`: Optional API key

### `client.getQuote(symbol, params)`

Get a single stock quote.

```javascript
const quote = await client.getQuote('AAPL', { method: 'yahoojson' });
```

### `client.getQuotes(symbols, params)`

Get multiple quotes.

```javascript
const quotes = await client.getQuotes(['AAPL', 'GOOGL'], { 
  method: 'yahoojson',
  currency: 'EUR'
});
```

### `client.getMethods()`

Get list of available quote methods.

### `client.getCurrency(fromCurrency, toCurrency)`

Get currency conversion rate.

### `client.healthCheck()`

Check API health.

## Convenience Functions

```javascript
const { quote, quotes, currency } = require('financequote');

// Single quote
await quote('AAPL');

// Multiple quotes
await quotes(['AAPL', 'GOOGL']);

// Currency
await currency('USD', 'EUR');
```

## Available Quote Methods

- `yahoojson` - Yahoo Finance (default, no API key)
- `alphavantage` - AlphaVantage (requires API key)
- `twelvedata` - Twelve Data (requires API key)
- `financeapi` - FinanceAPI (requires API key)
- And 40+ more...

## Error Handling

```javascript
const { FinanceQuoteClient } = require('financequote');

const client = new FinanceQuoteClient('http://localhost:3001');

try {
  const quote = await client.getQuote('INVALID_SYMBOL');
} catch (err) {
  console.error('Error:', err.message);
}
```

## TypeScript Support

The client includes TypeScript definitions:

```typescript
import { FinanceQuoteClient } from 'financequote';

const client = new FinanceQuoteClient('http://localhost:3001');
const quote = await client.getQuote('AAPL');
```

## Environment Variables

```javascript
const client = new FinanceQuoteClient(
  process.env.FQ_URL || 'http://localhost:3001',
  process.env.FQ_API_KEY
);
```