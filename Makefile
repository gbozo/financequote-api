# FinanceQuote API - Makefile
# Build and run commands

.PHONY: help build up down prod restart logs clean test health buildlocal upbuildlocal downbuildlocal restartbuildlocal logsbuildlocal cleanbuildlocal testbuildlocal healthbuildlocal

# Default target
help:
	@echo "FinanceQuote API - Makefile"
	@echo ""
	@echo "Available targets for production:"
	@echo "  build   - Build Docker image"
	@echo "  up      - Start development environment"
	@echo "  down    - Stop containers"
	@echo "  prod    - Start production environment"
	@echo "  restart - Restart containers"
	@echo "  logs    - View container logs"
	@echo "  health  - Check API health"
	@echo "  clean   - Clean up containers"
	@echo "  test    - Test API endpoints"
	@echo "  push    - Clean up containers"
	
	@echo "Available targets for local dev:"
	@echo "  buildlocal    - Build Local Docker image"
	@echo "  uplocal       - Start development environment"
	@echo "  uplocalnotdetached - Start development environment with not detached console"
	@echo "  downlocal     - Stop local container"
	@echo "  restartlocal  - Restart containers"
	@echo "  logslocal     - View local container logs"
	@echo "  healthlocal   - Check local container API health"
	@echo "  cleanlocal   - Stops and removes local container"
	@echo "  testlocal    - Test local API endpoint (/api/v1/methods)"
	@echo "  testlocalmethods:  - Test local API endpoint (/api/v1/methods)"
	@echo "  testlocalquote:    - Test local API endpoint (/api/v1/quote)"
	@echo "  testlocalinfo:     - Test local API endpoint (/api/v1/info)"
	@echo "  testlocalcurrency: - Test local API endpoint (/api/v1/currency)"
	@echo "  testlocalmcp:      - Test local API endpoint (/mcp)"

# Configuration
COMPOSE_FILE = docker-compose.yaml
COMPOSE_FILE_LOCAL = docker-compose.local.yaml

buildlocal:
	docker build -t financequote-api:local -f docker/Dockerfile .

uplocal:
	docker compose -f $(COMPOSE_FILE_LOCAL) up --build -d

uplocalnotdetached:
	docker compose -f $(COMPOSE_FILE_LOCAL) up --build -d

downlocal:
	docker compose -f $(COMPOSE_FILE_LOCAL) down

restartlocal:
	docker compose -f $(COMPOSE_FILE_LOCAL) restart

logslocal:
	docker compose -f $(COMPOSE_FILE_LOCAL) logs -f

healthlocal:
	@curl -s http://localhost:3002/api/v1/health || echo "API not responding"

cleanlocal:
	docker compose -f $(COMPOSE_FILE_LOCAL) down -v
	docker rmi financequote-api:local || true

testlocalmethods:
	@echo "Testing methods:" 
	@curl -s http://localhost:3002/api/v1/methods |head -20
	@echo

testlocalquote:
	@echo "Testing quote AAPL:"
	@curl -s http://localhost:3002/api/v1/quote/AAPL | head -20
	@echo

testlocalinfo:
	@echo "Testing info AAPL:"
	@curl -s http://localhost:3002/api/v1/info/AAPL | head -20
	@echo

testlocalcurrency:
	@echo "Testing currency USD -> EUR:"
	@curl -s http://localhost:3002/api/v1/currency/USD/EUR | head -20
	@echo

testlocalmcp:
	@echo "Testing mcp:"
	@curl -s -X POST http://localhost:3002/mcp -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | head -20
	@echo

build:
	docker build -t financequote-api:latest -f docker/Dockerfile .

up:
	docker compose -f $(COMPOSE_FILE) up --build

down:
	docker compose -f $(COMPOSE_FILE) down

prod:
	docker compose -f $(COMPOSE_FILE) up -d --build

restart:
	docker compose -f $(COMPOSE_FILE) restart

logs:
	docker compose -f $(COMPOSE_FILE) logs -f

health:
	@curl -s http://localhost:3001/api/v1/health || echo "API not responding"

clean:
	docker compose -f $(COMPOSE_FILE) down -v
	docker rmi financequote-api:latest || true

test:
	@echo "Testing API endpoints..."
	@curl -s http://localhost:3001/api/v1/methods | head -20
	@curl -s http://localhost:3001/api/v1/health

push:
	docker push ghcr.io/gbozo/financequote-api:latest