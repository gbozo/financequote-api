# FinanceQuote API - Makefile
# Build and run commands

.PHONY: help build up down prod restart logs clean test health

# Default target
help:
	@echo "FinanceQuote API - Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  build    - Build Docker image"
	@echo "  up      - Start development environment"
	@echo "  down    - Stop containers"
	@echo "  prod    - Start production environment"
	@echo "  restart - Restart containers"
	@echo "  logs    - View container logs"
	@echo "  health  - Check API health"
	@echo "  clean   - Clean up containers"

# Configuration
APP_PORT ?= 3000
COMPOSE_FILE = docker/docker-compose.yaml

build:
	docker build -t financequote-api:latest -f $(COMPOSE_FILE)/../Dockerfile .

up:
	APP_PORT=$(APP_PORT) docker-compose -f $(COMPOSE_FILE) up --build

down:
	docker-compose -f $(COMPOSE_FILE) down

prod:
	APP_ENV=production APP_PORT=3000 docker-compose -f $(COMPOSE_FILE) up -d --build

restart:
	docker-compose -f $(COMPOSE_FILE) restart

logs:
	docker-compose -f $(COMPOSE_FILE) logs -f

health:
	@curl -s http://localhost:$(APP_PORT)/api/v1/health || echo "API not responding"

clean:
	docker-compose -f $(COMPOSE_FILE) down -v
	docker rmi financequote-api:latest || true

test:
	@echo "Testing API endpoints..."
	@curl -s http://localhost:$(APP_PORT)/api/v1/methods | head -20
	@curl -s http://localhost:$(APP_PORT)/api/v1/health