# Suggested Commands

## Local Development
```bash
make buildlocal          # Build local Docker image
make uplocal             # Start dev environment (detached)
make uplocalnotdetached  # Start dev (foreground)
make downlocal           # Stop local container
make restartlocal        # Restart (needed after psgi changes)
make logslocal           # View container logs
make healthlocal         # curl health endpoint
make cleanlocal          # Stop + remove + delete image
```

## Testing
```bash
make testlocalmethods    # GET /api/v1/methods
make testlocalquote      # GET /api/v1/quote/AAPL
make testlocalinfo       # GET /api/v1/info/AAPL
make testlocalcurrency   # GET /api/v1/currency/USD/EUR
make testlocalmcp        # POST /mcp (initialize)
```

## Production
```bash
make build    # Build production image
make prod     # Start production (detached)
make down     # Stop
make logs     # View logs
make health   # Health check
make push     # Push to ghcr.io
```

## Release
```bash
git tag v1.x.x
git push origin main --tags
gh release create v1.x.x --title "v1.x.x" --generate-notes
```

## System
- macOS (Darwin), zsh
- git, docker, docker compose, gh (GitHub CLI), curl
