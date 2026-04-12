# FinanceQuote API - Dockerfile
# Installs Finance::Quote from CPAN for latest version

FROM debian:bookworm-slim

LABEL maintainer="financequote@example.com"
LABEL description="Finance::Quote REST API"
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
    && rm -rf /var/lib/apt/lists/*

# Install cpanm and all Perl dependencies including Finance::Quote
RUN curl -sL https://cpanmin.us | perl - App::cpanminus && \
    cpanm --notest Plack Starman JSON::XS String::Util HTML::TableExtract Web::Scraper Text::Template Date::Manip Time::Piece Date::Parse && \
    cpanm --notest Finance::Quote

# Create app user
RUN groupadd -g 1000 appgroup && useradd -m -u 1000 -g appgroup appuser

# Copy CPANM modules to a world-readable location  
RUN cp -r /root/.cpanm /opt/perl && chmod -R a+rX /opt/perl

# Create directory structure  
WORKDIR /app

# Copy API application
COPY ../api/app/bin/app.psgi /app/app.psgi

# Copy public documentation
COPY ../api/app/public /app/public

# Fix permissions - make sure lib directory is readable
RUN chown -R appuser:appgroup /app && chmod -R a+rX /app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 3000

# Set PERL5LIB to find CPAN modules
ENV PERL5LIB=/opt/perl/lib/perl5

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
    CMD curl -f http://localhost:3000/api/v1/health || exit 1

# Run using plackup
CMD ["plackup", "-s", "Starman", "-l", "0.0.0.0:3000", "/app/app.psgi"]