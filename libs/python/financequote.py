"""
FinanceQuote Python Client

A simple client library for the FinanceQuote API.
"""

import requests
from typing import Optional, Dict, List, Any


class FinanceQuoteClient:
    """Client for FinanceQuote API."""
    
    def __init__(self, base_url: str, api_key: Optional[str] = None):
        """
        Initialize the client.
        
        Args:
            base_url: The API base URL (e.g., "http://localhost:3001")
            api_key: Optional API key for authentication
        """
        self.base_url = base_url.rstrip('/')
        self.api_key = api_key
        self.session = requests.Session()
    
    def _get_headers(self) -> Dict[str, str]:
        """Get request headers including auth."""
        headers = {'Content-Type': 'application/json'}
        if self.api_key:
            headers['Authorization'] = f'Bearer {self.api_key}'
        return headers
    
    def get_quote(self, symbol: str, method: str = 'yahoojson', 
                  currency: Optional[str] = None) -> Dict[str, Any]:
        """
        Get a single stock quote.
        
        Args:
            symbol: Stock ticker symbol (e.g., "AAPL")
            method: Quote method (default: "yahoojson")
            currency: Optional currency for conversion
        
        Returns:
            Quote data dictionary
        """
        result = self.get_quotes([symbol], method, currency)
        if symbol in result:
            return result[symbol]
        raise ValueError(f"No quote found for {symbol}")
    
    def get_quotes(self, symbols: List[str], method: str = 'yahoojson',
                   currency: Optional[str] = None) -> Dict[str, Dict[str, Any]]:
        """
        Get quotes for multiple symbols.
        
        Args:
            symbols: List of stock ticker symbols (e.g., ["AAPL", "GOOGL"])
            method: Quote method (default: "yahoojson")
            currency: Optional currency for conversion
        
        Returns:
            Dictionary mapping symbol to quote data
        """
        if not symbols:
            raise ValueError("At least one symbol required")
        
        url = f"{self.base_url}/api/v1/quote/{','.join(symbols)}"
        
        params = {}
        if method:
            params['method'] = method
        if currency:
            params['currency'] = currency
        
        response = self.session.get(url, headers=self._get_headers(), params=params)
        response.raise_for_status()
        
        data = response.json()
        
        if data.get('status') != 'success':
            error_info = data.get('error', {})
            raise ValueError(f"API error: {error_info.get('message', 'Unknown error')}")
        
        # Filter out non-quote data
        result = {k: v for k, v in data.get('data', {}).items() 
                  if k != 'methods' and isinstance(v, dict)}
        
        return result
    
    def get_methods(self) -> List[str]:
        """
        Get all available quote methods.
        
        Returns:
            List of available methods
        """
        url = f"{self.base_url}/api/v1/methods"
        
        response = self.session.get(url, headers=self._get_headers())
        response.raise_for_status()
        
        data = response.json()
        return data.get('data', {}).get('methods', [])
    
    def get_currency(self, from_currency: str, to_currency: str) -> float:
        """
        Get currency conversion rate.
        
        Args:
            from_currency: Source currency code (e.g., "USD")
            to_currency: Target currency code (e.g., "EUR")
        
        Returns:
            Conversion rate
        """
        url = f"{self.base_url}/api/v1/currency/{from_currency}/{to_currency}"
        
        response = self.session.get(url, headers=self._get_headers())
        response.raise_for_status()
        
        data = response.json()
        
        if data.get('status') != 'success':
            error_info = data.get('error', {})
            raise ValueError(f"Currency error: {error_info.get('message', 'Unknown error')}")
        
        # The API returns {status: "success", data: {from, to, rate}}
        rate_data = data.get('data', {})
        rate = rate_data.get('rate', 0)
        
        return float(rate)
    
    def health_check(self) -> bool:
        """
        Check if the API is healthy.
        
        Returns:
            True if healthy, False otherwise
        """
        try:
            url = f"{self.base_url}/api/v1/health"
            response = self.session.get(url)
            return response.status_code == 200
        except requests.RequestException:
            return False


# Convenience functions

def quote(symbol: str, url: str = "http://localhost:3001", 
          api_key: Optional[str] = None, **kwargs) -> Dict[str, Any]:
    """
    Get a single stock quote.
    
    Example:
        >>> quote("AAPL", "http://localhost:3001")
        {'symbol': 'AAPL', 'last': 260.48, ...}
    """
    client = FinanceQuoteClient(url, api_key)
    return client.get_quote(symbol, **kwargs)


def quotes(symbols: List[str], url: str = "http://localhost:3001",
           api_key: Optional[str] = None, **kwargs) -> Dict[str, Dict[str, Any]]:
    """
    Get multiple stock quotes.
    
    Example:
        >>> quotes(["AAPL", "GOOGL"], "http://localhost:3001")
        {'AAPL': {...}, 'GOOGL': {...}}
    """
    client = FinanceQuoteClient(url, api_key)
    return client.get_quotes(symbols, **kwargs)


def currency(from_curr: str, to_curr: str, 
             url: str = "http://localhost:3001",
             api_key: Optional[str] = None) -> float:
    """
    Get currency conversion rate.
    
    Example:
        >>> currency("USD", "EUR", "http://localhost:3001")
        0.92
    """
    client = FinanceQuoteClient(url, api_key)
    return client.get_currency(from_curr, to_curr)


# Example usage
if __name__ == "__main__":
    # Initialize client
    client = FinanceQuoteClient("http://localhost:3001")
    
    # Get single quote
    apple = client.get_quote("AAPL")
    print(f"Apple: ${apple['last']}")
    
    # Get multiple quotes
    quotes = client.get_quotes(["AAPL", "GOOGL", "MSFT"])
    for symbol, data in quotes.items():
        print(f"{symbol}: ${data.get('last', 'N/A')}")
    
    # Get available methods
    methods = client.get_methods()
    print(f"Available methods: {len(methods)}")
    
    # Check health
    print(f"API healthy: {client.health_check()}")