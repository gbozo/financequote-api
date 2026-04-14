// Package financequote provides a Go client for the FinanceQuote API.
package financequote

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// Client represents a FinanceQuote API client
type Client struct {
	BaseURL    string
	APIKey     string
	httpClient *http.Client
}

// NewClient creates a new FinanceQuote API client
// baseURL: e.g., "http://localhost:3001"
// apiKey: optional, leave empty if API authentication is disabled
func NewClient(baseURL string, apiKey string) *Client {
	return &Client{
		BaseURL:    strings.TrimRight(baseURL, "/"),
		APIKey:     apiKey,
		httpClient: &http.Client{},
	}
}

// QuoteParams holds parameters for quote requests
type QuoteParams struct {
	Method   string // e.g., "yahoojson", "alphavantage"
	Currency string // e.g., "USD", "EUR"
}

// Quote represents a single stock quote
type Quote struct {
	Symbol    string  `json:"symbol"`
	Name      string  `json:"name"`
	Last      float64 `json:"last,string"`
	Date      string  `json:"date"`
	Time      string  `json:"time"`
	Currency  string  `json:"currency"`
	Success   int     `json:"success"`
	Method    string  `json:"method"`
	Exchange  string  `json:"exchange"`
	Open      float64 `json:"open,string"`
	High      float64 `json:"high,string"`
	Low       float64 `json:"low,string"`
	Close     float64 `json:"close,string"`
	Volume    int     `json:"volume,string"`
	MarketCap int64   `json:"market_cap,string"`
	EPS       float64 `json:"eps,string"`
	PE        float64 `json:"pe,string"`
	DivYield  float64 `json:"div_yield,string"`
	YearRange string  `json:"year_range"`
}

// Response represents the API response
type Response struct {
	Status    string                 `json:"status"`
	Data      map[string]interface{} `json:"data"`
	Timestamp string                 `json:"timestamp"`
}

// ErrorResponse represents an error response
type ErrorResponse struct {
	Status string `json:"status"`
	Error  struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Details string `json:"details"`
	} `json:"error"`
}

// GetQuote fetches a quote for a single symbol
// symbol: e.g., "AAPL"
func (c *Client) GetQuote(symbol string, params *QuoteParams) (*Quote, error) {
	result, err := c.GetQuotes([]string{symbol}, params)
	if err != nil {
		return nil, err
	}
	if quote, ok := result[symbol]; ok {
		return quote, nil
	}
	return nil, fmt.Errorf("no quote found for %s", symbol)
}

// GetQuotes fetches quotes for multiple symbols
// symbols: e.g., []string{"AAPL", "GOOGL", "MSFT"}
func (c *Client) GetQuotes(symbols []string, params *QuoteParams) (map[string]*Quote, error) {
	if len(symbols) == 0 {
		return nil, fmt.Errorf("at least one symbol required")
	}

	// Build URL
	url := fmt.Sprintf("%s/api/v1/quote/%s", c.BaseURL, strings.Join(symbols, ","))

	if params != nil {
		query := ""
		if params.Method != "" {
			query += "method=" + params.Method
		}
		if params.Currency != "" {
			if query != "" {
				query += "&"
			}
			query += "currency=" + params.Currency
		}
		if query != "" {
			url += "?" + query
		}
	}

	// Create request
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	// Add API key header if set
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	// Make request
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Parse response
	var result Response
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	if result.Status != "success" {
		if errMsg, ok := result.Data["error"]; ok {
			return nil, fmt.Errorf("API error: %v", errMsg)
		}
		return nil, fmt.Errorf("API error: unknown")
	}

	// Convert to quotes map
	quotes := make(map[string]*Quote)
	for symbol, data := range result.Data {
		if symbol == "methods" {
			continue
		}
		jsonData, err := json.Marshal(data)
		if err != nil {
			continue
		}
		var quote Quote
		if err := json.Unmarshal(jsonData, &quote); err != nil {
			continue
		}
		quotes[symbol] = &quote
	}

	return quotes, nil
}

// GetMethods returns all available quote methods
func (c *Client) GetMethods() ([]string, error) {
	url := fmt.Sprintf("%s/api/v1/methods", c.BaseURL)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result Response
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	methodsData, ok := result.Data["methods"].([]interface{})
	if !ok {
		return nil, fmt.Errorf("unexpected response format for methods")
	}
	methods := make([]string, 0, len(methodsData))
	for _, m := range methodsData {
		if s, ok := m.(string); ok {
			methods = append(methods, s)
		}
	}

	return methods, nil
}

// CurrencyRate represents a currency conversion rate
type CurrencyRate struct {
	From string  `json:"from"`
	To   string  `json:"to"`
	Rate float64 `json:"rate"`
}

// GetCurrency fetches currency conversion rate
func (c *Client) GetCurrency(from, to string) (*CurrencyRate, error) {
	url := fmt.Sprintf("%s/api/v1/currency/%s/%s", c.BaseURL, from, to)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result Response
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	if result.Status != "success" {
		return nil, fmt.Errorf("currency conversion failed")
	}

	// API returns {status: "success", data: {from, to, rate}}
	rateVal, ok := result.Data["rate"]
	if !ok {
		return nil, fmt.Errorf("rate not found in response")
	}
	rate, ok := rateVal.(float64)
	if !ok {
		return nil, fmt.Errorf("unexpected rate type in response")
	}

	return &CurrencyRate{
		From: from,
		To:   to,
		Rate: rate,
	}, nil
}

// HealthCheck checks if the API is healthy
func (c *Client) HealthCheck() (bool, error) {
	url := fmt.Sprintf("%s/api/v1/health", c.BaseURL)

	resp, err := c.httpClient.Get(url)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	return resp.StatusCode == 200, nil
}
