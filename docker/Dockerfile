# FinanceQuote API - Dockerfile
# Installs Finance::Quote from CPAN for latest version

FROM debian:bookworm-slim

LABEL maintainer="4042540+gbozo@users.noreply.github.com"
LABEL description="FinanceQuote API"
LABEL version="1.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    libssl3 \
    perl \
    build-essential \
    libnet-ssleay-perl \
    libio-socket-ssl-perl \
    libwww-perl \
    libtimedate-perl \
    libhtml-parser-perl \
    libhtml-tagset-perl \
    libtry-tiny-perl \
    libjson-perl \
    python3 \
    python3-pip \
    python3-venv \
    cron \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages, cpanm and all Perl dependencies including Finance::Quote
RUN python3 -m pip install --no-cache-dir --break-system-packages financedatabase && \
    curl -sL https://cpanmin.us | perl - App::cpanminus && \
    cpanm --notest Plack Starman JSON::XS String::Util HTML::TableExtract Web::Scraper Text::Template Date::Manip Time::Piece Date::Parse && \
    cpanm --notest Finance::Quote Finance::Quote::BVB DBD::SQLite

# Create app user
RUN groupadd -g 1000 appgroup && useradd -m -u 1000 -g appgroup appuser

# Copy CPANM modules to a world-readable location  
RUN cp -r /root/.cpanm /opt/perl && chmod -R a+rX /opt/perl

# Create directory structure  
WORKDIR /app

# Copy App folder
COPY ../app/ /app

# Copy cron scripts
COPY ../cron-scripts /usr/local/bin/

# Copy cron file (before switching to non-root)
COPY ../cron-scripts/financequote.cron /etc/cron.d/financequote
RUN chmod 0644 /etc/cron.d/financequote && \
    mkdir -p /var/run && chmod 1777 /var/run && \
    touch /var/log/cron.log && \
    chown appuser:appgroup /var/log/cron.log

# Fix permissions - make sure lib directory is readable
RUN chown -R appuser:appgroup /app /var/log/cron.log && chmod -R a+rX /app

# Switch to non-root user
USER appuser

# Run database import on startup, then cron and plackup
CMD ["sh", "-c", "python3 /usr/local/bin/import_financedatabase.py && (crontab /etc/cron.d/financequote && exec cron -f) & exec plackup -s Starman -l 0.0.0.0:3000 /app/app.psgi"]