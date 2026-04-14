package FQUtils;

use strict;
use warnings;
use JSON::XS qw(encode_json);

# API version - single source of truth
our $VERSION = '1.69';

sub get_timestamp {
    my ($sec,$min,$hour,$mday,$mon,$year) = gmtime(time());
    $mon += 1;
    $year += 1900;
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $year, $mon, $mday, $hour, $min, $sec);
}

sub standard_headers {
    return [ 'Content-Type' => 'application/json', 'Access-Control-Allow-Origin' => '*' ];
}

sub build_cache_key {
    my ($prefix, @parts) = @_;
    return join(':', grep { defined && $_ ne '' } $prefix, @parts);
}

sub process_quote_results {
    my ($quotes, $syms) = @_;
    my $sep = $;;  # subscript separator (chr(28) = 0x1C)
    my %result;
    foreach my $sym (@$syms) {
        foreach my $key (keys %$quotes) {
            # Use index() not split() to avoid encoding issues with $;
            my $pos = index($key, $sep);
            next if $pos < 0;
            my $s = substr($key, 0, $pos);
            my $attr = substr($key, $pos + 1);
            next unless $s eq $sym;
            $result{$sym}{$attr} = $quotes->{$key};
        }
        $result{$sym} //= { symbol => $sym, success => 0, errormsg => 'No data returned' };
    }
    return \%result;
}

sub url_decode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

sub sanitize_input {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/['"]//g;
    return $str;
}

sub json_response {
    my $status = shift;
    my $data = shift;
    my $code = shift // 200;
    
    my $response = {
        status => $status,
        data => $data,
        timestamp => get_timestamp(),
    };
    
    return [ $code, standard_headers(), [ encode_json($response) ] ];
}

sub error_response {
    my $code = shift;
    my $message = shift;
    my $details = shift // '';
    
    my $response = {
        status => 'error',
        error => {
            code => $code,
            message => $message,
            details => $details,
        },
        timestamp => get_timestamp(),
    };
    
    return [ $code, standard_headers(), [ encode_json($response) ] ];
}

sub jsonrpc_response {
    my ($id, $result) = @_;
    my $resp = {
        jsonrpc => '2.0',
        id      => $id,
        result  => $result,
    };
    return [ 200, standard_headers(), [ encode_json($resp) ] ];
}

sub jsonrpc_error {
    my ($id, $code, $message, $data) = @_;
    my $resp = {
        jsonrpc => '2.0',
        id      => $id,
        error   => {
            code    => $code,
            message => $message,
            (defined $data ? (data => $data) : ()),
        },
    };
    return [ 200, standard_headers(), [ encode_json($resp) ] ];
}

sub json_error_response {
    my ($code, $message, $data) = @_;
    my $resp = {
        jsonrpc => '2.0',
        id      => undef,
        error   => {
            code    => $code,
            message => $message,
            (defined $data ? (data => $data) : ()),
        },
    };
    return [ 200, standard_headers(), [ encode_json($resp) ] ];
}

# ============================================
# OpenAPI Specification Generator
# ============================================

my @api_routes;

sub register_route {
    my ($path, $method, $opts) = @_;
    push @api_routes, {
        path => $path,
        method => $method,
        summary => $opts->{summary} // '',
        description => $opts->{description} // '',
        params => $opts->{params} // [],
        responses => $opts->{responses} // {},
    };
}

sub get_openapi_spec {
    my (%opts) = @_;
    my $version = $opts{version} // $VERSION;
    my $fq_version = $opts{fq_version} // 'unknown';
    
    my %spec = (
        openapi => '3.0.3',
        info => {
            title => 'FinanceQuote API',
            description => "REST API wrapper for Perl's Finance::Quote library ($fq_version) and FinanceDatabase python library with MCP support.",
            version => $version,
        },
        servers => [
            { url => '{SERVER_URL}', description => 'Current server' }
        ],
        paths => {},
        components => {
            schemas => {
                Error => {
                    type => 'object',
                    properties => {
                        status => { type => 'string', example => 'error' },
                        error => {
                            type => 'object',
                            properties => {
                                code => { type => 'integer' },
                                message => { type => 'string' },
                                details => { type => 'string' },
                            },
                        },
                        timestamp => { type => 'string', format => 'date-time' },
                    },
                },
                Success => {
                    type => 'object',
                    properties => {
                        status => { type => 'string', example => 'success' },
                        data => { type => 'object' },
                        timestamp => { type => 'string', format => 'date-time' },
                    },
                },
                Quote => {
                    type => 'object',
                    properties => {
                        symbol => { type => 'string' },
                        name => { type => 'string' },
                        last => { type => 'number' },
                        close => { type => 'number' },
                        high => { type => 'number' },
                        low => { type => 'number' },
                        volume => { type => 'integer' },
                        currency => { type => 'string' },
                        exchange => { type => 'string' },
                        success => { type => 'integer' },
                    },
                },
            },
        },
    );
    
    foreach my $route (@api_routes) {
        my $path = $route->{path};
        $path =~ s/\{(\w+)\}/{$1}/g;
        
        $spec{paths}{$path}{$route->{method}} = {
            summary => $route->{summary},
            description => $route->{description},
            parameters => _build_parameters($route->{params}),
            responses => {
                '200' => {
                    description => 'Successful response',
                    content => {
                        'application/json' => {
                            schema => { type => 'object' },
                        },
                    },
                },
                '400' => {
                    description => 'Bad request',
                    content => {
                        'application/json' => {
                            schema => { '$ref' => '#/components/schemas/Error' },
                        },
                    },
                },
                '401' => {
                    description => 'Unauthorized',
                    content => {
                        'application/json' => {
                            schema => { '$ref' => '#/components/schemas/Error' },
                        },
                    },
                },
                '404' => {
                    description => 'Not found',
                    content => {
                        'application/json' => {
                            schema => { '$ref' => '#/components/schemas/Error' },
                        },
                    },
                },
                %{$route->{responses}},
            },
        };
    }
    
    return \%spec;
}

sub _build_parameters {
    my ($params) = @_;
    my @result;
    foreach my $p (@$params) {
        push @result, {
            name => $p->{name},
            in => $p->{in} // 'query',
            required => $p->{required} // 0,
            description => $p->{description} // '',
            schema => { type => $p->{type} // 'string' },
        };
    }
    return \@result;
}

sub generate_openapi_yaml {
    my (%opts) = @_;
    my $spec = get_openapi_spec(%opts);
    
    my $yaml = "openapi: 3.0.3\n";
    $yaml .= "info:\n";
    $yaml .= "  title: $spec->{info}{title}\n";
    $yaml .= "  description: |\n    $spec->{info}{description}\n";
    $yaml .= "  version: $spec->{info}{version}\n";
    $yaml .= "servers:\n";
    foreach my $srv (@{$spec->{servers}}) {
        $yaml .= "  - url: $srv->{url}\n";
        $yaml .= "    description: $srv->{description}\n" if $srv->{description};
    }
    $yaml .= "paths:\n";
    
    foreach my $path (sort keys %{$spec->{paths}}) {
        $yaml .= "  $path:\n";
        foreach my $method (sort keys %{$spec->{paths}{$path}}) {
            my $op = $spec->{paths}{$path}{$method};
            $yaml .= "    $method:\n";
            $yaml .= "      summary: $op->{summary}\n" if $op->{summary};
            $yaml .= "      description: $op->{description}\n" if $op->{description};
            
            if ($op->{parameters} && @{$op->{parameters}}) {
                $yaml .= "      parameters:\n";
                foreach my $p (@{$op->{parameters}}) {
                    $yaml .= "        - name: $p->{name}\n";
                    $yaml .= "          in: $p->{in}\n";
                    $yaml .= "          required: " . ($p->{required} ? 'true' : 'false') . "\n";
                    $yaml .= "          description: $p->{description}\n" if $p->{description};
                    $yaml .= "          schema:\n";
                    $yaml .= "            type: $p->{schema}{type}\n";
                }
            }
            
            if ($op->{responses}) {
                $yaml .= "      responses:\n";
                foreach my $code (sort keys %{$op->{responses}}) {
                    $yaml .= "        '$code':\n";
                    $yaml .= "          description: $op->{responses}{$code}{description}\n";
                }
            }
        }
    }
    
    $yaml .= "components:\n";
    $yaml .= "  schemas:\n";
    $yaml .= "    Error:\n";
    $yaml .= "      type: object\n";
    $yaml .= "    Success:\n";
    $yaml .= "      type: object\n";
    $yaml .= "    Quote:\n";
    $yaml .= "      type: object\n";
    
    return $yaml;
}

1;
