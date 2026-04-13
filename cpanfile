# FinanceQuote API - Perl Dependencies
# Generated for cpanm

# Core modules (usually included)
requires 'perl', '5.16.0';

# Finance::Quote dependencies
requires 'LWP::UserAgent', '6.00';
requires 'HTTP::Request', '6.00';
requires 'HTTP::Message', '6.00';
requires 'HTTP::Request::Common', '6.00';
requires 'URI', '1.00';
requires 'URI::Escape', '3.00';
requires 'Encode', '3.00';
requires 'JSON', '4.00';
requires 'Data::Dumper', '2.00';
requires 'Module::Load', '0.00';
requires 'Carp', '1.00';
requires 'Exporter', '0.00';
requires 'Encode', '3.00';

# SSL support
requires 'Net::SSLeay', '1.00';
requires 'IO::Socket::SSL', '2.00';

# Time and date handling
requires 'Time::HiRes', '0.00';
requires 'Time::Local', '1.00';
requires 'POSIX', '0.00';

# HTML/XML parsing (for some quote sources)
requires 'HTML::Parser', '3.00';
requires 'HTML::Tagset', '3.00';

# Error handling
requires 'Try::Tiny', '0.00';

# Object system
requires 'Mouse', '0.00';
requires 'Class::Load', '0.00';

# Web framework (Dancer2 alternative - minimal PSGI)
requires 'Plack', '1.00';
requires 'Starman', '0.4000';

# For local::lib contained installation
requires 'local::lib', '2.000024';

# Development/test dependencies
on 'test' => sub {
    requires 'Test::More', '0.00';
    requires 'Test::Exception', '0.00';
};

# Install all Finance::Quote dependencies as well
# These are included in the Finance-Quote CPAN distribution
# but we list core ones here for explicit installation