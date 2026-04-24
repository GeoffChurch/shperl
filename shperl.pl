#!/usr/bin/env perl
# Single-file Perl port of the shpool-table TUI. Wraps
# `shpool list --json`, `shpool attach`, and `shpool kill` behind a
# raw-mode terminal interface.
#
# Core-only dependencies: JSON::PP, POSIX, Time::HiRes.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX ();
use Time::HiRes qw(time);

$| = 1;

# ---------------------------------------------------------------------------
# Globals consulted by the cleanup END block. Populated when we enter
# raw mode / alt screen so a die() still restores the terminal.
# ---------------------------------------------------------------------------
our $SAVED_STTY;
our $IN_ALT = 0;

END {
    # ?1004l: disable focus reporting before the alt-screen flip so the
    # terminal isn't briefly emitting focus bytes into the user's shell
    # on the way out.
    print STDOUT "\e[?25h\e[?7h\e[?1004l\e[?1049l" if $IN_ALT;
    if (defined $SAVED_STTY) {
        system 'stty', $SAVED_STTY;
    }
}

# ---------------------------------------------------------------------------
# Top-level flags forwarded verbatim to every `shpool` shell-out. Mirrors
# shpool's own global flags so `shperl --socket /tmp/s2 -vv` behaves
# like `shpool --socket /tmp/s2 -vv list / attach / kill`. Set once in
# main(); read by fetch_sessions, shell_attach, the kill shell-out, and
# the no-nest guard.
#
# --daemonize / --no-daemonize are deliberately absent: auto-launching
# a daemon from under the TUI mid-session is confusing UX. The `D` key
# binding is the user-driven way to start one.
# ---------------------------------------------------------------------------
my @SHPOOL_FLAGS;

# ---------------------------------------------------------------------------
# SGR codes for the chrome. Phosphor-amber on a dark bar background.
# ---------------------------------------------------------------------------
my $SGR_RESET        = "\e[0m";
my $SGR_BAR_BG       = "\e[48;5;236m";
my $SGR_BAR_END      = "\e[49m";
my $SGR_AMBER        = "\e[1;38;2;235;185;90m";
my $SGR_AMBER_DIM    = "\e[38;2;130;105;75m";
my $SGR_ERROR        = "\e[1;38;2;255;120;100m";
my $SGR_BAR_FG_RESET = "\e[22;39m";
my $SGR_SELECTED     = "\e[7m";

# ---------------------------------------------------------------------------
# Normal-mode key bindings. Also the single source of truth for the
# footer hints. Trigger is [kind, byte] with kind 'byte' for plain ASCII
# or 'csi' for ESC [ <byte> sequences.
# ---------------------------------------------------------------------------
# Case synonyms (J/K/N/Q) are listed explicitly rather than folded at
# lookup time, so case-distinct bindings — d=kill vs. D=daemon — are
# pure data, not a special case in the dispatcher.
my @NORMAL_BINDINGS = (
    { label => 'j', desc => 'down', maps => [
        [ ['csi',  ord 'B'], 'Down' ],
        [ ['byte', ord 'j'], 'Down' ],
        [ ['byte', ord 'J'], 'Down' ],
    ]},
    { label => 'k', desc => 'up', maps => [
        [ ['csi',  ord 'A'], 'Up' ],
        [ ['byte', ord 'k'], 'Up' ],
        [ ['byte', ord 'K'], 'Up' ],
    ]},
    { label => 'spc', desc => 'attach', maps => [
        [ ['byte', ord ' '], 'Enter' ],
        [ ['byte', 0x0d],    'Enter' ],
        [ ['byte', 0x0a],    'Enter' ],
    ]},
    { label => 'n', desc => 'new',  maps => [
        [ ['byte', ord 'n'], 'NewSession' ],
        [ ['byte', ord 'N'], 'NewSession' ],
    ]},
    { label => 'd', desc => 'kill', maps => [ [ ['byte', ord 'd'], 'KillSession' ] ]},
    { label => 'D', desc => 'daemon', maps => [ [ ['byte', ord 'D'], 'EnsureDaemon' ] ]},
    { label => 'q', desc => 'quit', maps => [
        [ ['byte', ord 'q'], 'Quit' ],
        [ ['byte', ord 'Q'], 'Quit' ],
        [ ['byte', 0x03],    'Quit' ],
    ]},
);

my @CREATE_HINTS        = ( [ 'ret', 'create'  ], [ 'esc', 'cancel' ] );
my @CONFIRM_KILL_HINTS  = ( [ 'y',   'confirm' ], [ 'n',   'cancel' ] );
my @CONFIRM_FORCE_HINTS = ( [ 'y',   'force'   ], [ 'n',   'cancel' ] );

# Precomputed dispatch tables built once from @NORMAL_BINDINGS.
my (%BYTE_KEY, %CSI_KEY);
for my $bind (@NORMAL_BINDINGS) {
    for my $m (@{$bind->{maps}}) {
        my ($trig, $key) = @$m;
        if ($trig->[0] eq 'byte') {
            $BYTE_KEY{ $trig->[1] } = $key;
        } else {
            $CSI_KEY{ $trig->[1] } = $key;
        }
    }
}

# Map a token (['byte', b] | ['csi', b] | ['bare_esc']) to a Key
# string, for normal-mode dispatch. Unmapped tokens become 'Other'.
sub token_to_key {
    my $t = shift;
    if ($t->[0] eq 'byte') {
        return $BYTE_KEY{ $t->[1] } // 'Other';
    }
    if ($t->[0] eq 'csi') {
        return $CSI_KEY{ $t->[1] } // 'Other';
    }
    return 'Other';    # bare_esc
}

# ---------------------------------------------------------------------------
# Session fetch + model
# ---------------------------------------------------------------------------
# Optional @extra args go between the global flags and the subcommand —
# used by the D=daemon binding to slip in `--daemonize` so shpool
# auto-forks a daemon if one isn't already running. Idempotent when it
# is.
sub fetch_sessions {
    my @extra = @_;
    open my $fh, '-|', 'shpool', @SHPOOL_FLAGS, @extra, 'list', '--json'
        or die "spawning shpool list --json: $!\n";
    my $json = do { local $/; <$fh> };
    close $fh;
    if ($? != 0) {
        die "`shpool list --json` failed\n";
    }
    my $reply = eval { JSON::PP::decode_json($json) };
    die "parsing shpool list JSON: $@" if $@;
    my $sessions = $reply->{sessions} // [];
    # Normalize the status string to a boolean at the boundary — we
    # only ever care about whether a session is currently attached
    # elsewhere, so the other status values and future variants can
    # be collapsed into "not attached".
    for my $s (@$sessions) {
        $s->{attached} = (($s->{status} // '') eq 'Attached') ? 1 : 0;
    }
    return $sessions;
}

sub last_active_ms {
    my $s = shift;
    my $a = $s->{last_connected_at_unix_ms}    // 0;
    my $b = $s->{last_disconnected_at_unix_ms} // 0;
    my $c = $s->{started_at_unix_ms}           // 0;
    my $m = $a;
    $m = $b if $b > $m;
    $m = $c if $c > $m;
    return $m;
}

sub model_new {
    return {
        sessions     => [],
        selected     => 0,
        mode         => 'normal',    # normal | create | kill | confirm_force
        mode_data    => '',          # create: partial name; kill/confirm_force: target name
        error        => undef,
        parser_state => 'normal',    # normal | esc | esc_bracket
    };
}

sub model_selected_name {
    my $m = shift;
    return undef unless @{$m->{sessions}};
    return undef if $m->{selected} >= @{$m->{sessions}};
    return $m->{sessions}[$m->{selected}]{name};
}

sub model_select_next {
    my $m = shift;
    return unless @{$m->{sessions}};
    $m->{selected} = ($m->{selected} + 1) % scalar @{$m->{sessions}};
}

sub model_select_prev {
    my $m = shift;
    return unless @{$m->{sessions}};
    if ($m->{selected} == 0) {
        $m->{selected} = $#{$m->{sessions}};
    } else {
        $m->{selected}--;
    }
}

# Replace session list, sorting newest-active first and preserving the
# previous selection by name where possible, otherwise clamping.
sub model_refresh {
    my ($m, $new) = @_;
    my @sorted = sort { last_active_ms($b) <=> last_active_ms($a) } @$new;
    my $prev_name = model_selected_name($m);
    my $prev_idx  = $m->{selected};
    $m->{sessions} = \@sorted;
    if (defined $prev_name) {
        for my $i (0 .. $#sorted) {
            if ($sorted[$i]{name} eq $prev_name) {
                $m->{selected} = $i;
                return;
            }
        }
    }
    my $last = @sorted ? $#sorted : 0;
    $m->{selected} = $prev_idx > $last ? $last : $prev_idx;
}

sub model_set_error {
    my ($m, $msg) = @_;
    $m->{error} = $msg;
}

# ---------------------------------------------------------------------------
# Input parsing + per-mode processing
# ---------------------------------------------------------------------------
# One state machine turns a byte buffer into a token list:
#   ['byte', b]   — regular byte
#   ['csi',  b]   — terminated CSI sequence, b is the final byte
#   ['bare_esc']  — unterminated ESC at the buffer boundary (bare Escape)
# State persists on the model so a CSI split across reads still parses.

sub parse_tokens {
    my ($m, $buf) = @_;
    my @tokens;
    for my $b (unpack 'C*', $buf) {
        my $s = $m->{parser_state};
        if ($s eq 'normal') {
            if ($b == 0x1b) { $m->{parser_state} = 'esc'; }
            else            { push @tokens, [ 'byte', $b ]; }
        }
        elsif ($s eq 'esc') {
            if ($b == ord '[') {
                $m->{parser_state} = 'esc_bracket';
            } else {
                # ESC + non-bracket: bare Escape plus following byte.
                push @tokens, [ 'bare_esc' ], [ 'byte', $b ];
                $m->{parser_state} = 'normal';
            }
        }
        else {
            # esc_bracket: consume params/intermediates until a final byte.
            if ($b >= 0x40 && $b <= 0x7e) {
                push @tokens, [ 'csi', $b ];
                $m->{parser_state} = 'normal';
            }
        }
    }
    if ($m->{parser_state} eq 'esc') {
        push @tokens, [ 'bare_esc' ];
        $m->{parser_state} = 'normal';
    }
    return \@tokens;
}

sub process_input {
    my ($buf, $m) = @_;
    my $tokens = parse_tokens($m, $buf);

    # Filter focus events (ESC [ I = gained, ESC [ O = lost) out of the
    # token stream. Focus-gained refreshes the session list silently —
    # catches state changes that happened in another window. Focus-lost
    # is discarded. Done before clearing $m->{error} so a focus event
    # alone doesn't wipe a pending error message.
    my @keep;
    my $focus_gained = 0;
    for my $t (@$tokens) {
        if ($t->[0] eq 'csi') {
            if    ($t->[1] == ord 'I') { $focus_gained = 1; next; }
            elsif ($t->[1] == ord 'O') { next; }
        }
        push @keep, $t;
    }
    refresh_sessions($m) if $focus_gained;
    return undef unless @keep;

    $m->{error} = undef;
    return process_normal(\@keep, $m)         if $m->{mode} eq 'normal';
    return process_create_input(\@keep, $m)   if $m->{mode} eq 'create';
    return process_confirm_kill(\@keep, $m)   if $m->{mode} eq 'kill';
    return process_confirm_force(\@keep, $m)  if $m->{mode} eq 'confirm_force';
    return undef;
}

sub process_normal {
    my ($tokens, $m) = @_;
    for my $t (@$tokens) {
        my $key = token_to_key($t);
        if    ($key eq 'Up')   { model_select_prev($m); }
        elsif ($key eq 'Down') { model_select_next($m); }
        elsif ($key eq 'Enter') {
            my $name = model_selected_name($m);
            if (defined $name) {
                # Live-check the attached flag at keypress time. The
                # cached value updates once per keystroke, which goes
                # stale fast if the user detaches elsewhere and then
                # sits on the shperl UI without pressing anything.
                refresh_sessions($m);
                my ($sess) = grep { $_->{name} eq $name } @{$m->{sessions}};
                return [ 'attach', $name ] if !$sess;    # let run_tui report "gone"
                if ($sess->{attached}) {
                    $m->{mode}      = 'confirm_force';
                    $m->{mode_data} = $name;
                    return undef;
                }
                return [ 'attach', $name ];
            }
        }
        elsif ($key eq 'NewSession') {
            $m->{mode}      = 'create';
            $m->{mode_data} = '';
            return undef;
        }
        elsif ($key eq 'KillSession') {
            my $name = model_selected_name($m);
            if (defined $name) {
                $m->{mode}      = 'kill';
                $m->{mode_data} = $name;
            }
            return undef;
        }
        elsif ($key eq 'EnsureDaemon') { return [ 'ensure_daemon' ]; }
        elsif ($key eq 'Quit') { return [ 'quit' ]; }
        # 'Other' — ignore
    }
    return undef;
}

sub process_create_input {
    my ($tokens, $m) = @_;
    for my $t (@$tokens) {
        if ($t->[0] eq 'bare_esc') {
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return undef;
        }
        next if $t->[0] eq 'csi';    # arrow keys etc. — silently ignored
        my $b = $t->[1];
        if ($b == 0x03) {
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return undef;
        }
        elsif ($b == 0x0d || $b == 0x0a) {
            if (length $m->{mode_data}) {
                my $name = $m->{mode_data};
                $m->{mode}      = 'normal';
                $m->{mode_data} = '';
                return [ 'create', $name ];
            }
        }
        elsif ($b == 0x7f || $b == 0x08) {
            $m->{mode_data} = substr($m->{mode_data}, 0, -1)
                if length $m->{mode_data};
        }
        elsif ($b >= 0x21 && $b <= 0x7e) {
            # Printable non-space ASCII (shpool rejects whitespace).
            $m->{mode_data} .= chr($b);
        }
    }
    return undef;
}

sub process_confirm_kill {
    my ($tokens, $m) = @_;
    for my $t (@$tokens) {
        if ($t->[0] eq 'byte' && ($t->[1] == ord 'y' || $t->[1] == ord 'Y')) {
            my $name = $m->{mode_data};
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return [ 'kill', $name ];
        }
        $m->{mode}      = 'normal';
        $m->{mode_data} = '';
        return undef;
    }
    return undef;
}

sub process_confirm_force {
    my ($tokens, $m) = @_;
    for my $t (@$tokens) {
        if ($t->[0] eq 'byte' && ($t->[1] == ord 'y' || $t->[1] == ord 'Y')) {
            my $name = $m->{mode_data};
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return [ 'attach_force', $name ];
        }
        $m->{mode}      = 'normal';
        $m->{mode_data} = '';
        return undef;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# TTY control
# ---------------------------------------------------------------------------
sub tty_enter_raw {
    return if defined $SAVED_STTY;
    chomp(my $saved = `stty -g`);
    die "stty -g failed\n" if $? != 0 || !length $saved;
    $SAVED_STTY = $saved;
    system('stty', 'raw', '-echo') == 0 or die "stty raw -echo failed\n";
}

sub tty_leave_raw {
    return unless defined $SAVED_STTY;
    system('stty', $SAVED_STTY);
    undef $SAVED_STTY;
}

sub tty_enter_alt {
    # 1049h: alt screen. 25l: hide cursor. ?1l: DECCKM off (arrows
    # send ESC[A/B/C/D instead of ESC O A/B/C/D). ?7l: DECAWM off, so
    # any off-by-one width accounting gets clipped at the margin
    # instead of wrapping. ?1004h: xterm focus reporting on, so the
    # terminal sends ESC [ I when it regains focus (parsed as a
    # silent refresh) and ESC [ O when it loses focus (discarded).
    # Best-effort — terminals without focus-reporting support ignore
    # the enable sequence.
    print STDOUT "\e[?1049h\e[?25l\e[?1l\e[?7l\e[?1004h";
    $IN_ALT = 1;
}

sub tty_leave_alt {
    # Mirror tty_enter_alt: turn focus reporting off before the
    # alt-screen exit so the terminal isn't briefly emitting focus
    # bytes into whatever consumes stdin next (the user's shell, or
    # the upcoming `shpool attach` child).
    print STDOUT "\e[?25h\e[?7h\e[?1004l\e[?1049l";
    $IN_ALT = 0;
}

# Clear visible area + home cursor. Preserves scrollback (no \e[3J).
sub tty_clear {
    print STDOUT "\e[2J\e[H";
}

sub tty_size {
    my $out = `stty size 2>/dev/null`;
    if ($out =~ /^(\d+)\s+(\d+)/) {
        return (0 + $2, 0 + $1);    # (cols, rows)
    }
    return (80, 24);
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
# A label is [ styled_bytes, visible_chars ]. The visible count is
# tracked separately from the styled bytes so the bar's trailing space
# fill can be sized without parsing ANSI.

sub label_new { return [ '', 0 ]; }

sub label_push_plain {
    my ($l, $s) = @_;
    $l->[0] .= $SGR_AMBER_DIM . $s . $SGR_BAR_FG_RESET;
    $l->[1] += length $s;
}

sub label_push_key {
    my ($l, $s) = @_;
    $l->[0] .= $SGR_AMBER . $s . $SGR_BAR_FG_RESET;
    $l->[1] += length $s;
}

sub label_push_error {
    my ($l, $s) = @_;
    $l->[0] .= $SGR_ERROR . $s . $SGR_BAR_FG_RESET;
    $l->[1] += length $s;
}

sub title_label {
    my $m = shift;
    my $n = scalar @{$m->{sessions}};
    my $l = label_new();
    label_push_key($l, "shpool ($n session" . ($n == 1 ? '' : 's') . ")");
    return $l;
}

sub normal_bindings_label {
    my $l = label_new();
    for my $i (0 .. $#NORMAL_BINDINGS) {
        label_push_plain($l, '   ') if $i > 0;
        label_push_key($l, $NORMAL_BINDINGS[$i]{label});
        label_push_plain($l, ' ');
        label_push_plain($l, $NORMAL_BINDINGS[$i]{desc});
    }
    return $l;
}

sub push_hints {
    my ($l, $hints) = @_;
    for my $i (0 .. $#$hints) {
        label_push_plain($l, ', ') if $i > 0;
        label_push_key($l,   $hints->[$i][0]);
        label_push_plain($l, ': ');
        label_push_plain($l, $hints->[$i][1]);
    }
}

sub create_input_label {
    my $input = shift;
    my $l = label_new();
    label_push_plain($l, 'new session: ');
    label_push_key($l,   $input);
    label_push_plain($l, '_   (');
    push_hints($l, \@CREATE_HINTS);
    label_push_plain($l, ')');
    return $l;
}

sub error_label {
    my $msg = shift;
    my $l = label_new();
    label_push_error($l, '! ');
    label_push_error($l, $msg);
    return $l;
}

sub confirm_kill_label {
    my $name = shift;
    my $l = label_new();
    label_push_plain($l, 'kill ');
    label_push_key($l,   qq{"$name"});
    label_push_plain($l, '?   (');
    push_hints($l, \@CONFIRM_KILL_HINTS);
    label_push_plain($l, ')');
    return $l;
}

sub confirm_force_label {
    my $name = shift;
    my $l = label_new();
    label_push_key($l,   qq{"$name"});
    label_push_plain($l, ' already attached. force-attach?   (');
    push_hints($l, \@CONFIRM_FORCE_HINTS);
    label_push_plain($l, ')');
    return $l;
}

# Clip a styled (ANSI+text) string so visible characters don't exceed
# `max_visible`. ESC [ ... <final> sequences pass through verbatim —
# they don't count as visible width, but they stay with their text.
sub clip_styled {
    my ($styled, $max_visible) = @_;
    my $out = '';
    my $visible = 0;
    my $esc = 0;        # 0 normal, 1 saw ESC, 2 inside CSI
    for my $ch (split //, $styled) {
        if ($esc == 0) {
            if ($ch eq "\e") {
                $out .= $ch;
                $esc = 1;
            } else {
                last if $visible >= $max_visible;
                $out .= $ch;
                $visible++;
            }
        }
        elsif ($esc == 1) {
            $out .= $ch;
            $esc = ($ch eq '[') ? 2 : 0;
        }
        else {
            $out .= $ch;
            my $o = ord $ch;
            $esc = 0 if $o >= 0x40 && $o <= 0x7e;
        }
    }
    return $out;
}

# Render one chrome bar: styled label embedded in a bar background,
# padded/clipped to `width` columns. Left-aligned bars get a 2-col
# leading pad; centered bars split the slack evenly.
sub render_bar {
    my ($width, $label, $align) = @_;
    my ($styled, $visible) = @$label;
    my ($lead, $trail);
    if ($align eq 'center') {
        my $slack = $width - $visible;
        $slack = 0 if $slack < 0;
        $lead  = int($slack / 2);
        $trail = $slack - $lead;
    } else {
        $lead  = 2;
        my $rem = $width - ($lead + $visible);
        $trail = $rem < 0 ? 0 : $rem;
    }
    my $avail = $width - $lead;
    $avail = 0 if $avail < 0;
    my $clipped = clip_styled($styled, $avail);
    return $SGR_BAR_BG
         . (' ' x $lead)
         . $clipped
         . (' ' x $trail)
         . $SGR_BAR_END
         . $SGR_RESET
         . "\r\n";
}

sub now_unix_ms { return int(time() * 1000); }

# Short relative-age: "now" under 5s, then Ns, Nm, Nh, Nd.
sub format_age {
    my ($now_ms, $then_ms) = @_;
    my $secs = $now_ms > $then_ms ? int(($now_ms - $then_ms) / 1000) : 0;
    return 'now'       if $secs < 5;
    return "${secs}s"  if $secs < 60;
    my $mins = int($secs / 60);
    return "${mins}m"  if $mins < 60;
    my $hours = int($mins / 60);
    return "${hours}h" if $hours < 24;
    return int($hours / 24) . 'd';
}

# Visible window [start, end) that keeps the selection on screen.
sub viewport {
    my ($total, $selected, $max_visible) = @_;
    return (0, $total) if $total <= $max_visible;
    my $half        = int($max_visible / 2);
    my $ideal_start = $selected > $half ? $selected - $half : 0;
    my $max_start   = $total - $max_visible;
    my $start = $ideal_start > $max_start ? $max_start : $ideal_start;
    return ($start, $start + $max_visible);
}

my $CHROME_LINES = 3;                 # top bar + header + bottom bar
my $COL_CREATED  = 'created';
my $COL_ACTIVE   = 'active';
my $COL_GAP      = 2;

sub clip_plain {
    my ($s, $max) = @_;
    return $s if length $s <= $max;
    return substr($s, 0, $max);
}

sub render {
    my ($m, $w, $h) = @_;
    my $out = '';

    # Clear + home.
    $out .= "\e[2J\e[H";

    $out .= render_bar($w, title_label($m), 'center');

    # Name column grows to fit the longest name, floored at len("name").
    my $name_width = 4;                # len("name")
    for my $s (@{$m->{sessions}}) {
        my $len = length $s->{name};
        $name_width = $len if $len > $name_width;
    }
    my $created_width = length $COL_CREATED;
    my $active_width  = length $COL_ACTIVE;
    my $gap = ' ' x $COL_GAP;

    my $header = clip_plain(
        sprintf("  %-*s%s%-*s%s%-*s",
            $name_width,    'name',
            $gap,
            $created_width, $COL_CREATED,
            $gap,
            $active_width,  $COL_ACTIVE),
        $w,
    );
    $out .= sprintf("%s%s%-*s%s\r\n",
        $SGR_BAR_BG, $SGR_AMBER_DIM, $w, $header, $SGR_RESET);

    if (!@{$m->{sessions}}) {
        $out .= "  (no sessions)\r\n";
    } else {
        my $now = now_unix_ms();
        my $max_visible = $h - $CHROME_LINES;
        $max_visible = 0 if $max_visible < 0;
        my ($start, $end) = viewport(scalar @{$m->{sessions}}, $m->{selected}, $max_visible);
        for my $i ($start .. $end - 1) {
            my $s = $m->{sessions}[$i];
            # 2-char prefix: [attached marker][selected arrow]. An
            # asterisk marks sessions attached elsewhere so the user
            # sees the state without having to hit Enter and get the
            # pre-flight rejection. ASCII so we don't depend on the
            # terminal's locale/font.
            my $dot   = $s->{attached}         ? '*' : ' ';
            my $arrow = ($i == $m->{selected}) ? '>' : ' ';
            my $created = format_age($now, $s->{started_at_unix_ms} // 0);
            my $active  = format_age($now, last_active_ms($s));
            my $text = clip_plain(
                sprintf("%s%s%-*s%s%-*s%s%-*s",
                    $dot, $arrow,
                    $name_width,    $s->{name},
                    $gap,
                    $created_width, $created,
                    $gap,
                    $active_width,  $active),
                $w,
            );
            if ($i == $m->{selected}) {
                $out .= sprintf("%s%-*s%s\r\n", $SGR_SELECTED, $w, $text, $SGR_RESET);
            } else {
                $out .= sprintf("%-*s\r\n", $w, $text);
            }
        }
    }

    my $bottom;
    if (defined $m->{error}) {
        $bottom = error_label($m->{error});
    } elsif ($m->{mode} eq 'normal') {
        $bottom = normal_bindings_label();
    } elsif ($m->{mode} eq 'create') {
        $bottom = create_input_label($m->{mode_data});
    } elsif ($m->{mode} eq 'confirm_force') {
        $bottom = confirm_force_label($m->{mode_data});
    } else {
        $bottom = confirm_kill_label($m->{mode_data});
    }
    $out .= render_bar($w, $bottom, 'left');

    return $out;
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
sub refresh_sessions {
    my ($m, @extra) = @_;
    my $new = eval { fetch_sessions(@extra) };
    if ($@) {
        my $err = $@;
        chomp $err;
        model_set_error($m, "shpool list: $err");
        return;
    }
    model_refresh($m, $new);
}

# Spawn `shpool attach <name>`, handing the TTY over to the child.
# Used for both Attach and Create (a name shpool doesn't know is
# created on the fly). Clears the rendered frame first so the user's
# freshly-attached shell starts on a clean viewport. Returns true on
# successful exit.
sub shell_attach {
    my ($name, $force) = @_;
    tty_clear();
    my @cmd = ('shpool', @SHPOOL_FLAGS, 'attach');
    push @cmd, '-f' if $force;
    push @cmd, $name;
    my $rc = system @cmd;
    return $rc == 0;
}

# Post-action tail shared by attach/create/kill: refresh the session
# list, reselect the target by name if still present, and park an
# error message if the action failed.
sub finish_action {
    my ($m, $name, $ok, $err_msg) = @_;
    refresh_sessions($m);
    for my $i (0 .. $#{$m->{sessions}}) {
        if ($m->{sessions}[$i]{name} eq $name) {
            $m->{selected} = $i;
            last;
        }
    }
    model_set_error($m, $err_msg) if !$ok;
}

# Capture stderr of a child process via a pipe. Returns ($ok, $stderr)
# where $ok is true iff the child exited with status 0.
sub run_capture_stderr {
    my @cmd = @_;
    pipe(my $r, my $w) or die "pipe: $!";
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        close $r;
        open STDERR, '>&', $w or POSIX::_exit(127);
        open STDOUT, '>', '/dev/null';
        close $w;
        no warnings 'exec';
        exec { $cmd[0] } @cmd;
        POSIX::_exit(127);
    }
    close $w;
    my $err = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    return ($? == 0, $err // '');
}

sub event_loop {
    my $m = shift;
    my $buf;
    while (1) {
        my ($w, $h) = tty_size();
        my $frame = render($m, $w, $h);
        print STDOUT $frame;

        my $n = sysread(STDIN, $buf, 16);
        if (!defined $n) {
            next if $!{EINTR};      # SIGWINCH — re-render
            die "read stdin: $!";
        }
        return [ 'quit' ] if $n == 0;
        my $action = process_input($buf, $m);
        if ($action) {
            # Handled inline so the alt-screen stays up — no point
            # bouncing out to run_tui for a refresh-shaped action.
            if ($action->[0] eq 'ensure_daemon') {
                refresh_sessions($m, '--daemonize');
                next;
            }
            return $action;
        }
        # In Normal mode, pick up sessions added/removed by other
        # clients since the last keypress. Skipped in modal modes so
        # typing doesn't storm shpool with list calls.
        refresh_sessions($m) if $m->{mode} eq 'normal';
    }
}

sub run_tui {
    my $m = shift;
    # Empty handler is enough to interrupt sysread on resize.
    $SIG{WINCH} = sub {};

    while (1) {
        tty_enter_raw();
        tty_enter_alt();
        my $action = eval { event_loop($m) };
        my $err = $@;
        tty_leave_alt();
        tty_leave_raw();
        die $err if $err;

        return unless $action;
        my ($cmd, @args) = @$action;

        if ($cmd eq 'attach') {
            my ($name) = @args;
            # Pre-flight: refresh and verify the session still exists
            # and is not already attached elsewhere. shpool reports
            # "already has a terminal attached" on stderr with exit 0,
            # and piping stderr breaks shpool's own detach detection,
            # so we check the attached flag here instead. If it raced
            # into Attached since the keystroke, fall into the
            # force-confirm prompt rather than silently no-opping.
            refresh_sessions($m);
            my ($sess) = grep { $_->{name} eq $name } @{$m->{sessions}};
            if (!$sess) {
                model_set_error($m, "session '$name' is gone");
                next;
            }
            if ($sess->{attached}) {
                $m->{mode}      = 'confirm_force';
                $m->{mode_data} = $name;
                next;
            }
            my $rc = shell_attach($name);
            finish_action($m, $name, $rc, "shpool attach $name failed");
        }
        elsif ($cmd eq 'attach_force') {
            my ($name) = @args;
            refresh_sessions($m);
            my ($sess) = grep { $_->{name} eq $name } @{$m->{sessions}};
            if (!$sess) {
                model_set_error($m, "session '$name' is gone");
                next;
            }
            my $rc = shell_attach($name, 1);
            finish_action($m, $name, $rc, "shpool attach -f $name failed");
        }
        elsif ($cmd eq 'create') {
            my ($name) = @args;
            # Pre-flight: reject names that already exist. `shpool
            # attach` is create-or-attach, so without this check a
            # duplicate name silently attaches (or flashes "already
            # has a terminal attached" on stderr and no-ops) — neither
            # is what the create prompt implies.
            refresh_sessions($m);
            if (grep { $_->{name} eq $name } @{$m->{sessions}}) {
                model_set_error($m, "session '$name' already exists");
                next;
            }
            my $rc = shell_attach($name);
            finish_action($m, $name, $rc, "shpool attach $name failed");
        }
        elsif ($cmd eq 'kill') {
            my ($name) = @args;
            refresh_sessions($m);
            if (!grep { $_->{name} eq $name } @{$m->{sessions}}) {
                model_set_error($m, "session '$name' is gone");
                next;
            }
            my ($rc, $err_out) = run_capture_stderr('shpool', @SHPOOL_FLAGS, 'kill', $name);
            $err_out =~ s/^\s+|\s+$//g;
            my $msg = length $err_out ? "kill $name: $err_out" : "kill $name failed";
            finish_action($m, $name, $rc, $msg);
        }
        elsif ($cmd eq 'quit') {
            return;
        }
    }
}

# Parse top-level flags from @ARGV into @SHPOOL_FLAGS. Mirrors the
# four global flags shpool itself accepts; everything is forwarded
# verbatim to every shpool shell-out. Unknown flags or stray positional
# args are a usage error.
sub parse_args {
    my ($config_file, $log_file, $socket);
    my $verbose = 0;
    GetOptions(
        'config-file=s' => \$config_file,
        'log-file=s'    => \$log_file,
        'socket=s'      => \$socket,
        'verbose|v+'    => \$verbose,
    ) or die "Usage: shperl [--config-file PATH] [--log-file PATH] [--socket PATH] [-v ...]\n";
    @ARGV == 0
        or die "shperl: unexpected argument(s): @ARGV\n";

    @SHPOOL_FLAGS = ();
    push @SHPOOL_FLAGS, '--config-file', $config_file if defined $config_file;
    push @SHPOOL_FLAGS, '--log-file',    $log_file    if defined $log_file;
    push @SHPOOL_FLAGS, ('-v') x $verbose;
    push @SHPOOL_FLAGS, '--socket',      $socket      if defined $socket;
}

sub main {
    parse_args();
    if (my $inside = $ENV{SHPOOL_SESSION_NAME}) {
        print STDERR <<"EOM";
shperl: inside shpool session "$inside" — won't run here. Nested sessions
        get messy (outer attach gets bumped on force, sessions created
        here inherit this env, ^D leaves you in the wrong layer). Detach
        first to manage sessions. Current list:

EOM
        exec { 'shpool' } 'shpool', @SHPOOL_FLAGS, 'list';
        die "exec shpool list: $!\n";
    }
    my $m = model_new();
    refresh_sessions($m);
    run_tui($m);
}

main() unless caller;

1;
