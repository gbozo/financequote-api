# Go Client for FinanceQuote API

A Go client library for the FinanceQuote REST API.

## Installation

```bash
go get github.com/gbozo/financequote-api/libs/go
```

## Usage

```go
package main

import (
	"fmt"
	"log"
	
	financequote "github.com/gbozo/financequote-api/libs/go"
)

func main() {
	// Create client (no auth)
	client := financequote.NewClient("http://localhost:3001", "")
	
	// Or with authentication
	// client := financequote.NewClient("http://localhost:3001", "my-api-key")
	
	// Get single quote
	quote, err := client.GetQuote("AAPL", nil)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("AAPL: $%.2f\n", quote.Last)
	
	// Get multiple quotes
	quotes, err := client.GetQuotes([]string{"AAPL", "GOOGL", "MSFT"}, nil)
	if err != nil {
		log.Fatal(err)
	}
	for symbol, q := range quotes {
		fmt.Printf("%s: $%.2f\n", symbol, q.Last)
	}
	
	// Get all available methods
	methods, err := client.GetMethods()
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Available methods: %v\n", methods)
	
	// Currency conversion
	rate, err := client.GetCurrency("USD", "EUR")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("USD to EUR: %.4f\n", rate)
	
	// Health check
	healthy, _ := client.HealthCheck()
	fmt.Printf("API healthy: %v\n", healthy)
}
```

## API Reference

### `NewClient(baseURL, apiKey string) *Client`

Create a new API client.

- `baseURL`: The API base URL (e.g., `http://localhost:3001`)
- `apiKey`: Optional API key for authentication

### `GetQuote(symbol string, params *QuoteParams) (*Quote, error)`

Fetch a single stock quote.

### `GetQuotes(symbols []string, params *QuoteParams) (map[string]*Quote, error)`

Fetch multiple stock quotes.

### `GetMethods() ([]string, error)`

Get all available quote methods.

### `GetCurrency(from, to string) (*CurrencyRate, error)`

Get currency conversion rate.

### `HealthCheck() (bool, error)`

Check if the API is healthy.

## Quote Parameters

```go
params := &financequote.QuoteParams{
    Method:   "yahoojson",  // Quote source
    Currency: "EUR",         // Target currency
}
quote, _ := client.GetQuote("AAPL", params)
```

## Available Quote Methods

- `yahoojson` - Yahoo Finance (default, no API key)
- `alphavantage` - AlphaVantage (requires API key)
- `twelvedata` - Twelve Data (requires API key)
- `financeapi` - FinanceAPI (requires API key)
- And 40+ more...