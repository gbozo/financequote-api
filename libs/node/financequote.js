/**
 * FinanceQuote Node.js Client
 * A simple client library for the FinanceQuote API.
 */

const http = require('http');
const https = require('https');

class FinanceQuoteClient {
  /**
   * Create a new FinanceQuote API client.
   * @param {string} baseURL - The API base URL (e.g., "http://localhost:3001")
   * @param {string} [apiKey] - Optional API key for authentication
   */
  constructor(baseURL, apiKey = null) {
    this.baseURL = baseURL.replace(/\/$/, '');
    this.apiKey = apiKey;
  }

  _getHeaders() {
    const headers = { 'Content-Type': 'application/json' };
    if (this.apiKey) {
      headers['Authorization'] = `Bearer ${this.apiKey}`;
    }
    return headers;
  }

  _makeRequest(path) {
    return new Promise((resolve, reject) => {
      const url = new URL(path, this.baseURL);
      const client = url.protocol === 'https:' ? https : http;

      const options = {
        hostname: url.hostname,
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: url.pathname + url.search,
        method: 'GET',
        headers: this._getHeaders()
      };

      const req = client.request(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (json.status === 'success') {
              resolve(json.data);
            } else {
              reject(new Error(json.error?.message || 'API error'));
            }
          } catch (e) {
            reject(e);
          }
        });
      });

      req.on('error', reject);
      req.end();
    });
  }

  /**
   * Get a single stock quote.
   * @param {string} symbol - Stock ticker symbol (e.g., "AAPL")
   * @param {object} [params] - Optional parameters
   * @param {string} [params.method] - Quote method (default: "yahoojson")
   * @param {string} [params.currency] - Currency for conversion
   * @returns {Promise<object>} Quote data
   */
  async getQuote(symbol, params = {}) {
    const symbols = await this.getQuotes([symbol], params);
    if (symbols[symbol]) {
      return symbols[symbol];
    }
    throw new Error(`No quote found for ${symbol}`);
  }

  /**
   * Get quotes for multiple symbols.
   * @param {string[]} symbols - Array of stock ticker symbols
   * @param {object} [params] - Optional parameters
   * @param {string} [params.method] - Quote method (default: "yahoojson")
   * @param {string} [params.currency] - Currency for conversion
   * @returns {Promise<object>} Dictionary of quotes
   */
  async getQuotes(symbols, params = {}) {
    if (!symbols || symbols.length === 0) {
      throw new Error('At least one symbol required');
    }

    const query = new URLSearchParams();
    if (params.method) query.set('method', params.method);
    if (params.currency) query.set('currency', params.currency);

    const path = `/api/v1/quote/${symbols.join(',')}${query.toString() ? '?' + query.toString() : ''}`;
    const data = await this._makeRequest(path);

    // Filter out non-quote data
    const result = {};
    for (const [key, value] of Object.entries(data)) {
      if (key !== 'methods' && typeof value === 'object') {
        result[key] = value;
      }
    }
    return result;
  }

  /**
   * Get all available quote methods.
   * @returns {Promise<string[]>} List of available methods
   */
  async getMethods() {
    const data = await this._makeRequest('/api/v1/methods');
    return data.methods || [];
  }

  /**
   * Get currency conversion rate.
   * @param {string} fromCurrency - Source currency code (e.g., "USD")
   * @param {string} toCurrency - Target currency code (e.g., "EUR")
   * @returns {Promise<number>} Conversion rate
   */
  async getCurrency(fromCurrency, toCurrency) {
    // API returns {status: "success", data: {from, to, rate}}
    const data = await this._makeRequest(`/api/v1/currency/${fromCurrency}/${toCurrency}`);
    if (data && data.rate !== undefined) {
      return parseFloat(data.rate);
    }
    throw new Error('Currency rate not available');
  }

  /**
   * Check if the API is healthy.
   * @returns {Promise<boolean>} True if healthy
   */
  async healthCheck() {
    try {
      const data = await this._makeRequest('/api/v1/health');
      return data && data.service === 'FinanceQuote API';
    } catch {
      return false;
    }
  }
}

// Convenience functions
async function quote(symbol, url = 'http://localhost:3001', apiKey = null, params = {}) {
  const client = new FinanceQuoteClient(url, apiKey);
  return client.getQuote(symbol, params);
}

async function quotes(symbols, url = 'http://localhost:3001', apiKey = null, params = {}) {
  const client = new FinanceQuoteClient(url, apiKey);
  return client.getQuotes(symbols, params);
}

async function currency(from, to, url = 'http://localhost:3001', apiKey = null) {
  const client = new FinanceQuoteClient(url, apiKey);
  return client.getCurrency(from, to);
}

// Export for CommonJS and ES modules
module.exports = {
  FinanceQuoteClient,
  quote,
  quotes,
  currency
};

// Example usage
if (require.main === module) {
  (async () => {
    const client = new FinanceQuoteClient('http://localhost:3001');

    try {
      // Get single quote
      const apple = await client.getQuote('AAPL');
      console.log('Apple:', apple.last);

      // Get multiple quotes
      const quotes = await client.getQuotes(['AAPL', 'GOOGL', 'MSFT']);
      for (const [symbol, data] of Object.entries(quotes)) {
        console.log(`${symbol}: $${data.last || 'N/A'}`);
      }

      // Get methods
      const methods = await client.getMethods();
      console.log(`Available methods: ${methods.length}`);

      // Health check
      console.log(`API healthy: ${await client.healthCheck()}`);
    } catch (err) {
      console.error('Error:', err.message);
    }
  })();
}