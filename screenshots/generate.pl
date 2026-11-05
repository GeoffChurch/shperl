#!/usr/bin/env perl
# The README's screenshots: renders shperl's two screens from one shared
# state and draws each as an SVG in this directory. Run it after a
# change to the rendering; tests.pl fails while a committed SVG differs
# from what this would write. tests.pl loads it via require, like
# shperl.pl, and it writes only when it is the program.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

# The repo root, from this file's own location, so it's the same whether
# this runs directly or is required by tests.pl. Resolved like FindBin's
# Bin, so the require below matches tests.pl's and loads shperl.pl once.
my $ROOT = abs_path(dirname(__FILE__) . '/..');

require "$ROOT/shperl.pl";

# ---------------------------------------------------------------------------
# The state both screens show, so they agree: the variables screen counts
# the attachments of the sessions the table lists, and its candidate
# values come from those sessions' names.
# ---------------------------------------------------------------------------

my $SCREENSHOT_NOW = 1_000_000_000_000;
my $MINUTE         = 60_000;
my $HOUR           = 60 * $MINUTE;
my $DAY            = 24 * $HOUR;

# Fresh copies per call, since a model takes ownership of what it's given.
sub screenshot_sessions {
    return [
        { name => 'personal-mail', status => 'Attached', attached => 1,
          started_at_unix_ms => $SCREENSHOT_NOW - 5 * $HOUR,
          last_connected_at_unix_ms => $SCREENSHOT_NOW - 1 * $HOUR,
          last_disconnected_at_unix_ms => 0,
          window_title => 'NeoMutt with 2481 messages [12 NEW]',
          attachments => [
              { session_name_template => '{acct}-mail', pid => 2718 } ] },
        { name => 'work-mail', status => 'Disconnected', attached => 0,
          started_at_unix_ms => $SCREENSHOT_NOW - 90 * $DAY,
          last_connected_at_unix_ms => $SCREENSHOT_NOW - 90 * $DAY,
          last_disconnected_at_unix_ms => $SCREENSHOT_NOW - 89 * $DAY,
          window_title => 'NeoMutt with 9314 messages [9314 NEW]',
          attachments => [] },
        { name => 'djt-miner', status => 'Attached', attached => 1,
          started_at_unix_ms => $SCREENSHOT_NOW - 1461 * $DAY,
          last_connected_at_unix_ms => $SCREENSHOT_NOW - 3 * $HOUR,
          last_disconnected_at_unix_ms => 0,
          window_title => 'Coins mined: 23.203 ($0.00032). Level: patriot',
          attachments => [
              { session_name_template => 'djt-miner', pid => 4321 } ] },
        { name => 'vim', status => 'Attached', attached => 1,
          started_at_unix_ms => $SCREENSHOT_NOW - 10 * $MINUTE,
          last_connected_at_unix_ms => $SCREENSHOT_NOW - 4 * $MINUTE,
          last_disconnected_at_unix_ms => 0,
          window_title => 'nvme0n1 (/dev) - VIM',
          attachments => [
              { session_name_template => '{editor}', pid => 1234 } ] },
    ];
}

sub screenshot_vars {
    return [ { name => 'acct',   value => 'personal' },
             { name => 'editor', value => 'vim' } ];
}

my $SCREENSHOT_COLS = 82;

# Each screen: where its SVG goes, what the image says in words, and the
# frame shperl draws for it.
sub screenshots {
    no warnings qw(redefine once);
    local *main::now_unix_ms = sub { $SCREENSHOT_NOW };

    my $table = main::model_new();
    main::model_refresh($table, screenshot_sessions());
    $table->{selected} = 0;

    # Setting acct to work, with the re-dial preview showing
    # personal-mail's attachment moving to work-mail.
    my $vars = main::model_new();
    main::model_refresh($vars, screenshot_sessions());
    $vars->{mode} = 'vars';
    $vars->{vars}{list} = screenshot_vars();
    $vars->{vars}{sel}  = 0;                                # acct
    main::vars_edit_start($vars);                           # highlight: personal
    main::process_vars_input([ [csi=>ord 'B'] ], $vars);    # highlight: work

    return (
        { path  => 'screenshots/sessions.svg',
          alt   => 'main view',
          frame => main::render($table, $SCREENSHOT_COLS, 9) },
        { path  => 'screenshots/variables.svg',
          alt   => 'variables view',
          frame => main::render($vars, $SCREENSHOT_COLS, 12) },
    );
}

# ---------------------------------------------------------------------------
# Frame -> SVG
# ---------------------------------------------------------------------------

my $FONT_SIZE   = 14;
my $CELL_WIDTH  = 8.4;      # a monospace advance at $FONT_SIZE
my $LINE_HEIGHT = 18;
my $BASELINE    = 14;       # from a row's top
my $PADDING     = 14;
my $DEFAULT_FG  = '#d4d4d4';
my $DEFAULT_BG  = '#1e1e1e';
# No ui-monospace: where a system doesn't know it, fontconfig can stand
# a proportional font in for it rather than moving on down the list.
my $FONT_FAMILY = q{SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', 'Noto Sans Mono', 'Liberation Mono', monospace};

# Applies one SGR sequence's parameters to a style. Only the codes
# shperl emits are known; any other dies, so a new style in shperl.pl
# fails the screenshot test until it's drawn here.
sub apply_sgr {
    my ($style, $params) = @_;
    my @p = length $params ? split /;/, $params : (0);
    while (@p) {
        my $c = shift @p;
        if    ($c == 0)  { %$style = () }
        elsif ($c == 1)  { $style->{bold} = 1 }
        elsif ($c == 22) { delete $style->{bold} }
        elsif ($c == 7)  { $style->{reverse} = 1 }
        elsif ($c == 39) { delete $style->{fg} }
        elsif ($c == 49) { delete $style->{bg} }
        elsif (($c == 38 || $c == 48) && @p >= 4 && $p[0] == 2) {
            shift @p;
            $style->{$c == 38 ? 'fg' : 'bg'} = sprintf '#%02x%02x%02x', splice @p, 0, 3;
        }
        elsif (($c == 38 || $c == 48) && @p >= 2 && $p[0] == 5
               && $p[1] >= 232 && $p[1] <= 255) {
            shift @p;
            my $level = 8 + 10 * (shift(@p) - 232);     # xterm's gray ramp
            $style->{$c == 38 ? 'fg' : 'bg'} = sprintf '#%02x%02x%02x', ($level) x 3;
        }
        else { die "screenshot: unhandled SGR parameter $c in '$params'\n" }
    }
}

# The colors a cell is drawn with, after reverse video.
sub cell_colors {
    my $style = shift;
    my ($fg, $bg) = ($style->{fg} // $DEFAULT_FG, $style->{bg} // $DEFAULT_BG);
    return $style->{reverse} ? ($bg, $fg) : ($fg, $bg);
}

sub xml_escape {
    my $s = shift;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

# Splits a frame into rows of cells { ch, fg, bg, bold }, one per
# terminal column (a wide character takes its first column and leaves
# the next empty).
sub frame_cells {
    my $frame = shift;
    $frame =~ s/\A\e\[2J\e\[H// or die "screenshot: frame doesn't start with clear + home\n";
    my %style;
    my @rows;
    for my $line (split /\r\n/, $frame) {
        my @cells;
        for my $tok ($line =~ /(\e\[[\d;]*m|\e|.)/gs) {
            if ($tok =~ /\A\e\[([\d;]*)m\z/) { apply_sgr(\%style, $1); next }
            die "screenshot: unhandled escape in frame\n" if $tok eq "\e";
            my ($fg, $bg) = cell_colors(\%style);
            push @cells, { ch => $tok, fg => $fg, bg => $bg, bold => $style{bold} ? 1 : 0 };
            push @cells, { ch => '', fg => $fg, bg => $bg, bold => 0 }
                for 2 .. main::str_width($tok);
        }
        push @rows, \@cells;
    }
    return @rows;
}

# Runs of adjacent cells sharing $key's value: [ start column, cells ].
sub runs {
    my ($cells, $key) = @_;
    my @runs;
    for my $i (0 .. $#$cells) {
        my $k = $key->($cells->[$i]);
        if (@runs && $runs[-1][2] eq $k) { push @{$runs[-1][1]}, $cells->[$i] }
        else                             { push @runs, [ $i, [ $cells->[$i] ], $k ] }
    }
    return @runs;
}

# Each row's backgrounds, then its text, with every character placed at
# its own column, so the grid holds in whatever font the viewer ends up
# using and each glyph keeps its natural width. Spaces are left out of
# the text, since their columns are already in the positions and
# renderers differ on whether to collapse them (Chrome ignores
# xml:space="preserve"), which would shift every later position by one.
sub frame_svg {
    my ($frame, $cols, $alt) = @_;
    my @rows   = frame_cells($frame);
    my $width  = 2 * $PADDING + $cols * $CELL_WIDTH;
    my $height = 2 * $PADDING + @rows * $LINE_HEIGHT;
    my $svg = sprintf qq{<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g" viewBox="0 0 %g %g" role="img" aria-label="%s">\n},
        $width, $height, $width, $height, xml_escape($alt);
    $svg .= sprintf qq{<rect width="%g" height="%g" rx="8" fill="%s"/>\n}, $width, $height, $DEFAULT_BG;
    $svg .= sprintf qq{<g font-family="%s" font-size="%d">\n}, $FONT_FAMILY, $FONT_SIZE;
    for my $r (0 .. $#rows) {
        my $top = $PADDING + $r * $LINE_HEIGHT;
        for my $run (runs($rows[$r], sub { $_[0]{bg} })) {
            my ($col, $cells, $bg) = @$run;
            next if $bg eq $DEFAULT_BG;
            $svg .= sprintf qq{<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>\n},
                $PADDING + $col * $CELL_WIDTH, $top, @$cells * $CELL_WIDTH, $LINE_HEIGHT, $bg;
        }
        for my $run (runs($rows[$r], sub { "$_[0]{fg} $_[0]{bold}" })) {
            my ($col, $cells) = @$run;
            my (@xs, $text);
            for my $i (0 .. $#$cells) {
                my $ch = $cells->[$i]{ch};
                next if $ch eq ' ' || $ch eq '';        # '': a wide character's second column
                push @xs, $PADDING + ($col + $i) * $CELL_WIDTH;
                $text .= $ch;
            }
            next unless @xs;
            $svg .= sprintf qq{<text x="%s" y="%g" fill="%s"%s>%s</text>\n},
                join(' ', map { sprintf '%g', $_ } @xs), $top + $BASELINE,
                $cells->[0]{fg}, $cells->[0]{bold} ? ' font-weight="bold"' : '',
                xml_escape($text);
        }
    }
    $svg .= "</g>\n</svg>\n";
    return $svg;
}

sub screenshot_svg {
    my $shot = shift;
    return frame_svg($shot->{frame}, $SCREENSHOT_COLS, $shot->{alt});
}

sub write_screenshots {
    for my $shot (screenshots()) {
        my $path = "$ROOT/$shot->{path}";
        open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
        print $fh screenshot_svg($shot);
        close $fh or die "$path: $!";
        print "wrote $shot->{path}\n";
    }
}

write_screenshots() unless caller;

1;
