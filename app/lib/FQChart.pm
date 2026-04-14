package FQChart;

# FQChart - SVG stock card generator
# Produces self-contained SVG images with price charts, metrics, and company info.
# Three card sizes: small (400x250), medium (600x400), large (800x500).

use strict;
use warnings;
use POSIX qw(floor ceil);

# ============================================
# Card Size Configurations
# ============================================

my %SIZES = (
    small  => { width => 400, height => 250 },
    medium => { width => 600, height => 400 },
    large  => { width => 800, height => 500 },
);

# ============================================
# Color Palette
# ============================================

my %COLORS = (
    bg            => '#1a1a2e',
    bg_card       => '#16213e',
    bg_dark       => '#0f3460',
    text_primary  => '#e4e4e4',
    text_secondary => '#a0a0b0',
    text_muted    => '#6c6c80',
    green         => '#00c853',
    green_light   => '#69f0ae',
    red           => '#ff1744',
    red_light     => '#ff8a80',
    accent        => '#00bcd4',
    accent_dim    => '#006978',
    grid          => '#2a2a4a',
    border        => '#2a3a5e',
);

# ============================================
# Public API
# ============================================

sub generate_card {
    my (%opts) = @_;

    my $size     = $opts{size} || 'medium';
    my $symbol   = $opts{symbol} // 'N/A';
    my $name     = $opts{name} // '';
    my $price    = $opts{price};
    my $change   = $opts{change};
    my $pct_change = $opts{pct_change};
    my $currency = $opts{currency} // 'USD';
    my $exchange = $opts{exchange} // '';
    my $history  = $opts{history} // [];     # arrayref of { date, close, high, low, volume, ... }
    my $info     = $opts{info} // {};        # pe, yield, eps, cap, year_high, year_low, etc.
    my $db_info  = $opts{db_info} // {};     # sector, country, industry from DB

    my $dim = $SIZES{$size} || $SIZES{medium};
    my $w = $dim->{width};
    my $h = $dim->{height};

    my $is_positive = (defined $change && $change >= 0) ? 1 : 0;
    my $trend_color = $is_positive ? $COLORS{green} : $COLORS{red};
    my $trend_light = $is_positive ? $COLORS{green_light} : $COLORS{red_light};

    my $svg = '';
    $svg .= _svg_header($w, $h);
    $svg .= _svg_defs($w, $h, $trend_color);

    # Background
    $svg .= qq{<rect width="$w" height="$h" rx="12" fill="$COLORS{bg_card}" stroke="$COLORS{border}" stroke-width="1"/>\n};

    if ($size eq 'small') {
        $svg .= _render_small($w, $h, $symbol, $name, $price, $change, $pct_change,
                              $currency, $trend_color, $trend_light, $is_positive, $history);
    } elsif ($size eq 'medium') {
        $svg .= _render_medium($w, $h, $symbol, $name, $price, $change, $pct_change,
                               $currency, $exchange, $trend_color, $trend_light, $is_positive,
                               $history, $info);
    } else {
        $svg .= _render_large($w, $h, $symbol, $name, $price, $change, $pct_change,
                              $currency, $exchange, $trend_color, $trend_light, $is_positive,
                              $history, $info, $db_info);
    }

    $svg .= "</svg>\n";
    return $svg;
}

sub available_sizes {
    return { map { $_ => $SIZES{$_} } keys %SIZES };
}

# ============================================
# SVG Header / Defs
# ============================================

sub _svg_header {
    my ($w, $h) = @_;
    return qq{<?xml version="1.0" encoding="UTF-8"?>\n} .
           qq{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $w $h" width="$w" height="$h">\n};
}

sub _svg_defs {
    my ($w, $h, $trend_color) = @_;
    return qq{<defs>
  <linearGradient id="chartGrad" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="$trend_color" stop-opacity="0.3"/>
    <stop offset="100%" stop-color="$trend_color" stop-opacity="0.02"/>
  </linearGradient>
  <linearGradient id="bgGrad" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="$COLORS{bg_card}"/>
    <stop offset="100%" stop-color="$COLORS{bg}"/>
  </linearGradient>
  <filter id="shadow">
    <feDropShadow dx="0" dy="1" stdDeviation="2" flood-opacity="0.3"/>
  </filter>
</defs>\n};
}

# ============================================
# Small Card (400x250) - Symbol + Price + Sparkline
# ============================================

sub _render_small {
    my ($w, $h, $symbol, $name, $price, $change, $pct_change,
        $currency, $trend_color, $trend_light, $is_positive, $history) = @_;

    my $svg = '';

    # Symbol badge
    $svg .= _symbol_badge(16, 16, $symbol, 22, $COLORS{accent});

    # Truncated company name
    my $display_name = _truncate($name, 30);
    $svg .= _text(16, 50, $display_name, 13, $COLORS{text_secondary});

    # Price
    my $price_str = _format_price($price, $currency);
    $svg .= _text($w - 16, 35, $price_str, 26, $COLORS{text_primary}, 'end', 'bold');

    # Change
    my $change_str = _format_change($change, $pct_change, $is_positive);
    $svg .= _text($w - 16, 55, $change_str, 14, $trend_color, 'end');

    # Sparkline area (full width, bottom half)
    if (@$history >= 2) {
        my $chart_x = 16;
        my $chart_y = 75;
        my $chart_w = $w - 32;
        my $chart_h = $h - 95;
        $svg .= _sparkline($chart_x, $chart_y, $chart_w, $chart_h,
                           $history, $trend_color, 1);
    } else {
        $svg .= _text($w/2, $h/2 + 20, 'No chart data', 14, $COLORS{text_muted}, 'middle');
    }

    # Date range footer
    if (@$history >= 2) {
        my $first_date = $history->[0]{date} // '';
        my $last_date = $history->[-1]{date} // '';
        $svg .= _text(16, $h - 10, _short_date($first_date), 10, $COLORS{text_muted});
        $svg .= _text($w - 16, $h - 10, _short_date($last_date), 10, $COLORS{text_muted}, 'end');
    }

    return $svg;
}

# ============================================
# Medium Card (600x400) - Chart + Axes + Stats
# ============================================

sub _render_medium {
    my ($w, $h, $symbol, $name, $price, $change, $pct_change,
        $currency, $exchange, $trend_color, $trend_light, $is_positive,
        $history, $info) = @_;

    my $svg = '';

    # --- Header Section (top 80px) ---
    $svg .= _symbol_badge(20, 18, $symbol, 24, $COLORS{accent});

    my $display_name = _truncate($name, 35);
    if ($exchange) {
        $display_name .= "  ($exchange)";
    }
    $svg .= _text(20, 54, $display_name, 12, $COLORS{text_secondary});

    # Price block (right side)
    my $price_str = _format_price($price, $currency);
    $svg .= _text($w - 20, 38, $price_str, 28, $COLORS{text_primary}, 'end', 'bold');

    my $change_str = _format_change($change, $pct_change, $is_positive);
    $svg .= _text($w - 20, 58, $change_str, 14, $trend_color, 'end');

    # --- Separator line ---
    $svg .= qq{<line x1="20" y1="72" x2="} . ($w-20) . qq{" y2="72" stroke="$COLORS{grid}" stroke-width="0.5"/>\n};

    # --- Chart Area (80-300) ---
    my $chart_x = 60;
    my $chart_y = 85;
    my $chart_w = $w - 80;
    my $chart_h = 190;

    if (@$history >= 2) {
        $svg .= _chart_with_axes($chart_x, $chart_y, $chart_w, $chart_h,
                                 $history, $trend_color, $currency);
    } else {
        $svg .= _text($w/2, $chart_y + $chart_h/2, 'No chart data available', 14, $COLORS{text_muted}, 'middle');
    }

    # --- Stats Bar (bottom 100px) ---
    $svg .= qq{<line x1="20" y1="290" x2="} . ($w-20) . qq{" y2="290" stroke="$COLORS{grid}" stroke-width="0.5"/>\n};

    my @stats;

    # 52-week range
    my $y_high = $info->{year_high} // '';
    my $y_low  = $info->{year_low} // '';
    if ($y_high ne '' && $y_low ne '') {
        push @stats, { label => '52W High', value => _format_num($y_high) };
        push @stats, { label => '52W Low', value => _format_num($y_low) };
    }

    # Volume
    my $vol = $info->{volume} // '';
    if ($vol ne '') {
        push @stats, { label => 'Volume', value => _format_volume($vol) };
    }

    # Day range
    my $open = $info->{open} // '';
    if ($open ne '') {
        push @stats, { label => 'Open', value => _format_num($open) };
    }

    $svg .= _stats_row(20, 305, $w - 40, \@stats, 4);

    # 52-week range bar
    if ($y_high ne '' && $y_low ne '' && defined $price && $y_high != $y_low) {
        $svg .= _range_bar(20, 345, $w - 40, 18, $y_low+0, $y_high+0, $price+0, $trend_color, $currency);
    }

    # Date range footer
    if (@$history >= 2) {
        my $first_date = $history->[0]{date} // '';
        my $last_date = $history->[-1]{date} // '';
        my $count = scalar(@$history);
        $svg .= _text(20, $h - 10, _short_date($first_date) . " - " . _short_date($last_date) . " ($count days)", 10, $COLORS{text_muted});
    }

    return $svg;
}

# ============================================
# Large Card (800x500) - Full Analysis Card
# ============================================

sub _render_large {
    my ($w, $h, $symbol, $name, $price, $change, $pct_change,
        $currency, $exchange, $trend_color, $trend_light, $is_positive,
        $history, $info, $db_info) = @_;

    my $svg = '';

    # --- Header Section (top 80px) ---
    $svg .= _symbol_badge(24, 20, $symbol, 28, $COLORS{accent});

    my $display_name = _truncate($name, 50);
    my $subtitle = '';
    $subtitle .= $exchange if $exchange;
    if ($db_info->{sector}) {
        $subtitle .= ' | ' if $subtitle;
        $subtitle .= $db_info->{sector};
    }
    if ($db_info->{country}) {
        $subtitle .= ' | ' if $subtitle;
        $subtitle .= $db_info->{country};
    }
    $svg .= _text(24, 58, $display_name, 14, $COLORS{text_secondary});
    $svg .= _text(24, 74, $subtitle, 11, $COLORS{text_muted}) if $subtitle;

    # Price block (right side)
    my $price_str = _format_price($price, $currency);
    $svg .= _text($w - 24, 40, $price_str, 32, $COLORS{text_primary}, 'end', 'bold');

    my $change_str = _format_change($change, $pct_change, $is_positive);
    $svg .= _text($w - 24, 62, $change_str, 16, $trend_color, 'end');

    # Currency label
    $svg .= _text($w - 24, 78, $currency, 11, $COLORS{text_muted}, 'end');

    # --- Separator ---
    $svg .= qq{<line x1="24" y1="88" x2="} . ($w-24) . qq{" y2="88" stroke="$COLORS{grid}" stroke-width="0.5"/>\n};

    # --- Chart Area (90-310) ---
    my $chart_x = 70;
    my $chart_y = 98;
    my $chart_w = $w - 100;
    my $chart_h = 200;

    if (@$history >= 2) {
        $svg .= _chart_with_axes($chart_x, $chart_y, $chart_w, $chart_h,
                                 $history, $trend_color, $currency);
    } else {
        $svg .= _text($w/2, $chart_y + $chart_h/2, 'No chart data available', 16, $COLORS{text_muted}, 'middle');
    }

    # --- Metrics Section (310-400) ---
    $svg .= qq{<line x1="24" y1="310" x2="} . ($w-24) . qq{" y2="310" stroke="$COLORS{grid}" stroke-width="0.5"/>\n};

    # Row 1: Price metrics
    my @row1;
    my $y_high = $info->{year_high} // '';
    my $y_low  = $info->{year_low} // '';
    push @row1, { label => '52W High', value => _format_num($y_high) } if $y_high ne '';
    push @row1, { label => '52W Low', value => _format_num($y_low) } if $y_low ne '';
    push @row1, { label => 'Open', value => _format_num($info->{open}) } if defined $info->{open} && $info->{open} ne '';
    push @row1, { label => 'Volume', value => _format_volume($info->{volume}) } if defined $info->{volume} && $info->{volume} ne '';
    $svg .= _stats_row(24, 328, $w - 48, \@row1, 4) if @row1;

    # 52-week range bar
    if ($y_high ne '' && $y_low ne '' && defined $price && $y_high != $y_low) {
        $svg .= _range_bar(24, 350, $w - 48, 16, $y_low+0, $y_high+0, $price+0, $trend_color, $currency);
    }

    # Row 2: Fundamentals
    $svg .= qq{<line x1="24" y1="378" x2="} . ($w-24) . qq{" y2="378" stroke="$COLORS{grid}" stroke-width="0.5"/>\n};
    my @row2;
    push @row2, { label => 'P/E', value => _format_num($info->{pe}) } if defined $info->{pe} && $info->{pe} ne '';
    push @row2, { label => 'EPS', value => _format_num($info->{eps}) } if defined $info->{eps} && $info->{eps} ne '';
    push @row2, { label => 'Div Yield', value => (_format_num($info->{yield}) . '%') } if defined $info->{yield} && $info->{yield} ne '';
    push @row2, { label => 'Mkt Cap', value => _format_cap($info->{cap}) } if defined $info->{cap} && $info->{cap} ne '';
    $svg .= _stats_row(24, 396, $w - 48, \@row2, 4) if @row2;

    # Row 3: Company info from DB
    if ($db_info && (keys %$db_info > 0)) {
        $svg .= qq{<line x1="24" y1="420" x2="} . ($w-24) . qq{" y2="420" stroke="$COLORS{grid}" stroke-width="0.5"/>\n};
        my @row3;
        push @row3, { label => 'Sector', value => _truncate($db_info->{sector}, 18) } if $db_info->{sector};
        push @row3, { label => 'Industry', value => _truncate($db_info->{industry}, 18) } if $db_info->{industry};
        push @row3, { label => 'Country', value => _truncate($db_info->{country}, 18) } if $db_info->{country};
        push @row3, { label => 'Exchange', value => $db_info->{exchange} // $exchange } if $db_info->{exchange} || $exchange;
        $svg .= _stats_row(24, 438, $w - 48, \@row3, 4) if @row3;
    }

    # --- Footer ---
    if (@$history >= 2) {
        my $first_date = $history->[0]{date} // '';
        my $last_date  = $history->[-1]{date} // '';
        my $count = scalar(@$history);
        $svg .= _text(24, $h - 12, _short_date($first_date) . " - " . _short_date($last_date) . " ($count days)", 10, $COLORS{text_muted});
    }
    $svg .= _text($w - 24, $h - 12, "FinanceQuote API v$FQUtils::VERSION", 10, $COLORS{text_muted}, 'end');

    return $svg;
}

# ============================================
# Chart Components
# ============================================

sub _sparkline {
    my ($x, $y, $w, $h, $history, $color, $fill) = @_;
    return '' unless @$history >= 2;

    my @closes = map { $_->{close} // $_->{last} // 0 } @$history;
    @closes = grep { $_ > 0 } @closes;
    return '' unless @closes >= 2;

    my ($min, $max) = _min_max(\@closes);
    my $range = $max - $min || 1;

    my $n = scalar(@closes);
    my @points;
    for my $i (0 .. $#closes) {
        my $px = $x + ($i / ($n - 1)) * $w;
        my $py = $y + $h - (($closes[$i] - $min) / $range) * $h;
        push @points, sprintf("%.1f,%.1f", $px, $py);
    }

    my $svg = '';
    my $line_points = join(' ', @points);

    # Filled area under the line
    if ($fill) {
        my $area_points = $line_points .
            sprintf(" %.1f,%.1f %.1f,%.1f", $x + $w, $y + $h, $x, $y + $h);
        $svg .= qq{<polygon points="$area_points" fill="url(#chartGrad)" opacity="0.8"/>\n};
    }

    # Line
    $svg .= qq{<polyline points="$line_points" fill="none" stroke="$color" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>\n};

    # End dot
    my $last_point = $points[-1];
    my ($lx, $ly) = split(/,/, $last_point);
    $svg .= qq{<circle cx="$lx" cy="$ly" r="3" fill="$color"/>\n};

    return $svg;
}

sub _chart_with_axes {
    my ($x, $y, $w, $h, $history, $color, $currency) = @_;
    return '' unless @$history >= 2;

    my @closes = map { $_->{close} // $_->{last} // 0 } @$history;
    @closes = grep { $_ > 0 } @closes;
    return '' unless @closes >= 2;

    my ($min, $max) = _min_max(\@closes);
    # Add 5% padding
    my $range = $max - $min || 1;
    $min -= $range * 0.05;
    $max += $range * 0.05;
    $range = $max - $min;

    my $svg = '';

    # Y-axis grid lines and labels (5 lines)
    for my $i (0..4) {
        my $gy = $y + $h - ($i / 4) * $h;
        my $val = $min + ($i / 4) * $range;
        $svg .= qq{<line x1="$x" y1="$gy" x2="} . ($x + $w) . qq{" y2="$gy" stroke="$COLORS{grid}" stroke-width="0.5" stroke-dasharray="4,4"/>\n};
        $svg .= _text($x - 8, $gy + 4, _format_num($val), 10, $COLORS{text_muted}, 'end');
    }

    # X-axis date labels (max 5)
    my $n = scalar(@$history);
    my $label_count = $n < 5 ? $n : 5;
    for my $i (0 .. $label_count - 1) {
        my $idx = int($i / ($label_count - 1) * ($n - 1));
        $idx = $n - 1 if $idx >= $n;
        my $px = $x + ($idx / ($n - 1)) * $w;
        my $date_str = _short_date($history->[$idx]{date} // '');
        $svg .= _text($px, $y + $h + 14, $date_str, 10, $COLORS{text_muted}, 'middle');
    }

    # Chart line and fill
    my @points;
    for my $i (0 .. $#closes) {
        my $px = $x + ($i / (scalar(@closes) - 1)) * $w;
        my $py = $y + $h - (($closes[$i] - $min) / $range) * $h;
        push @points, sprintf("%.1f,%.1f", $px, $py);
    }

    my $line_points = join(' ', @points);

    # Gradient fill
    my $area_points = $line_points .
        sprintf(" %.1f,%.1f %.1f,%.1f", $x + $w, $y + $h, $x, $y + $h);
    $svg .= qq{<polygon points="$area_points" fill="url(#chartGrad)" opacity="0.6"/>\n};

    # Line
    $svg .= qq{<polyline points="$line_points" fill="none" stroke="$color" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>\n};

    # Volume bars (if available, bottom 20% of chart area)
    my @volumes = map { $_->{volume} // 0 } @$history;
    my $has_volume = grep { $_ > 0 } @volumes;
    if ($has_volume) {
        my ($vmin, $vmax) = _min_max([grep { $_ > 0 } @volumes]);
        $vmax ||= 1;
        my $bar_h_max = $h * 0.15;
        my $bar_w = ($w / scalar(@volumes)) * 0.7;
        $bar_w = 1 if $bar_w < 1;

        for my $i (0 .. $#volumes) {
            next unless $volumes[$i] > 0;
            my $bx = $x + ($i / (scalar(@volumes) - 1 || 1)) * $w - $bar_w/2;
            my $bh = ($volumes[$i] / $vmax) * $bar_h_max;
            my $by = $y + $h - $bh;
            $svg .= qq{<rect x="$bx" y="$by" width="$bar_w" height="$bh" fill="$COLORS{accent_dim}" opacity="0.4" rx="0.5"/>\n};
        }
    }

    # Endpoint marker
    my $last_point = $points[-1];
    my ($lx, $ly) = split(/,/, $last_point);
    $svg .= qq{<circle cx="$lx" cy="$ly" r="4" fill="$color" stroke="$COLORS{bg_card}" stroke-width="2"/>\n};

    return $svg;
}

sub _range_bar {
    my ($x, $y, $w, $h, $low, $high, $current, $color, $currency) = @_;
    return '' unless $high > $low;

    my $svg = '';
    my $bar_h = 6;
    my $bar_y = $y + ($h - $bar_h) / 2;

    # Background bar
    $svg .= qq{<rect x="$x" y="$bar_y" width="$w" height="$bar_h" rx="3" fill="$COLORS{grid}"/>\n};

    # Progress fill
    my $pct = ($current - $low) / ($high - $low);
    $pct = 0 if $pct < 0;
    $pct = 1 if $pct > 1;
    my $fill_w = $w * $pct;
    $svg .= qq{<rect x="$x" y="$bar_y" width="$fill_w" height="$bar_h" rx="3" fill="$color" opacity="0.6"/>\n};

    # Current position marker
    my $marker_x = $x + $fill_w;
    $svg .= qq{<circle cx="$marker_x" cy="} . ($bar_y + $bar_h/2) . qq{" r="5" fill="$color" stroke="$COLORS{bg_card}" stroke-width="2"/>\n};

    # Labels
    $svg .= _text($x, $y - 2, _format_num($low), 10, $COLORS{text_muted});
    $svg .= _text($x + $w, $y - 2, _format_num($high), 10, $COLORS{text_muted}, 'end');
    my $pct_text = sprintf("%.0f%%", $pct * 100);
    $svg .= _text($marker_x, $y - 2, $pct_text, 10, $color, 'middle');

    return $svg;
}

# ============================================
# Stats Components
# ============================================

sub _stats_row {
    my ($x, $y, $w, $stats, $max_cols) = @_;
    return '' unless $stats && @$stats;

    my $n = scalar(@$stats);
    $n = $max_cols if $n > $max_cols;
    my $col_w = $w / $n;

    my $svg = '';
    for my $i (0 .. $n - 1) {
        my $stat = $stats->[$i];
        my $cx = $x + $i * $col_w;
        $svg .= _text($cx, $y, $stat->{label}, 10, $COLORS{text_muted});
        $svg .= _text($cx, $y + 16, $stat->{value} // 'N/A', 13, $COLORS{text_primary}, 'start', 'bold');
    }
    return $svg;
}

sub _symbol_badge {
    my ($x, $y, $symbol, $size, $color) = @_;
    return _text($x, $y + $size, $symbol, $size, $color, 'start', 'bold');
}

# ============================================
# SVG Primitives
# ============================================

sub _text {
    my ($x, $y, $text, $size, $fill, $anchor, $weight) = @_;
    $anchor //= 'start';
    $weight //= 'normal';
    $text = _escape_xml($text // '');
    return qq{<text x="$x" y="$y" font-family="-apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif" font-size="$size" fill="$fill" text-anchor="$anchor" font-weight="$weight">$text</text>\n};
}

sub _escape_xml {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/'/&apos;/g;
    return $str;
}

# ============================================
# Formatting Helpers
# ============================================

sub _format_price {
    my ($price, $currency) = @_;
    return 'N/A' unless defined $price && $price ne '';
    my $p = $price + 0;
    my $symbol = _currency_symbol($currency);
    if ($p >= 1000) {
        return $symbol . _commify(sprintf("%.2f", $p));
    } elsif ($p >= 1) {
        return $symbol . sprintf("%.2f", $p);
    } else {
        return $symbol . sprintf("%.4f", $p);
    }
}

sub _format_change {
    my ($change, $pct, $is_positive) = @_;
    my $arrow = $is_positive ? "\x{25B2}" : "\x{25BC}";  # Up/down triangle
    my $sign = $is_positive ? '+' : '';
    my $c = defined $change ? sprintf("%.2f", $change) : '0.00';
    my $p = defined $pct ? sprintf("%.2f", $pct) : '0.00';
    return "$arrow ${sign}${c} (${sign}${p}%)";
}

sub _format_num {
    my ($val) = @_;
    return 'N/A' unless defined $val && $val ne '';
    my $n = $val + 0;
    if (abs($n) >= 1000) {
        return _commify(sprintf("%.2f", $n));
    } elsif (abs($n) >= 1) {
        return sprintf("%.2f", $n);
    } else {
        return sprintf("%.4f", $n);
    }
}

sub _format_volume {
    my ($vol) = @_;
    return 'N/A' unless defined $vol && $vol ne '';
    my $v = $vol + 0;
    if ($v >= 1_000_000_000) {
        return sprintf("%.1fB", $v / 1_000_000_000);
    } elsif ($v >= 1_000_000) {
        return sprintf("%.1fM", $v / 1_000_000);
    } elsif ($v >= 1_000) {
        return sprintf("%.1fK", $v / 1_000);
    }
    return sprintf("%.0f", $v);
}

sub _format_cap {
    my ($cap) = @_;
    return 'N/A' unless defined $cap && $cap ne '';
    my $c = $cap + 0;
    if ($c >= 1_000_000_000_000) {
        return sprintf("%.1fT", $c / 1_000_000_000_000);
    } elsif ($c >= 1_000_000_000) {
        return sprintf("%.1fB", $c / 1_000_000_000);
    } elsif ($c >= 1_000_000) {
        return sprintf("%.1fM", $c / 1_000_000);
    }
    return _commify(sprintf("%.0f", $c));
}

sub _commify {
    my ($n) = @_;
    my ($int, $dec) = split(/\./, $n, 2);
    $int =~ s/\B(?=(\d{3})+(?!\d))/,/g;
    return defined $dec ? "$int.$dec" : $int;
}

sub _currency_symbol {
    my ($code) = @_;
    my %symbols = (
        USD => '$', EUR => "\x{20AC}", GBP => "\x{00A3}", JPY => "\x{00A5}",
        CHF => 'CHF ', CNY => "\x{00A5}", KRW => "\x{20A9}", INR => "\x{20B9}",
        BRL => 'R$', AUD => 'A$', CAD => 'C$', HKD => 'HK$', SGD => 'S$',
        SEK => 'kr', NOK => 'kr', DKK => 'kr',
    );
    return $symbols{uc($code // '')} // ($code ? "$code " : '$');
}

sub _short_date {
    my ($date) = @_;
    return '' unless $date;
    # YYYY-MM-DD -> Mon DD
    if ($date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        my $m = ($2 + 0) - 1;
        $m = 0 if $m < 0 || $m > 11;
        return "$months[$m] $3";
    }
    return $date;
}

sub _truncate {
    my ($str, $max) = @_;
    return '' unless defined $str;
    return $str if length($str) <= $max;
    return substr($str, 0, $max - 3) . '...';
}

sub _min_max {
    my ($arr) = @_;
    my $min = $arr->[0];
    my $max = $arr->[0];
    for my $v (@$arr) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }
    return ($min, $max);
}

1;
