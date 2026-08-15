#!/usr/bin/env perl
# Single-file Perl port of the shpool-table TUI. Wraps `shpool list
# --json`, `shpool attach`, `shpool kill`, and (when available) `shpool
# events` behind a raw-mode terminal interface.
#
# Core-only dependencies: JSON::PP, POSIX, Time::HiRes.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Encode qw(decode_utf8);
use POSIX ();
use Time::HiRes qw(time);

$| = 1;

# ---------------------------------------------------------------------------
# Globals consulted by the cleanup END block. Populated when we enter
# raw mode / alt screen so a die() still restores the terminal.
# ---------------------------------------------------------------------------
our $SAVED_STTY;
our $IN_ALT = 0;
# Tracked here (not just on the model) so END can kill the events
# child on abnormal exit. The child blocks on read from the daemon
# socket and won't notice shperl is gone until it next tries to write
# (could be hours on an idle daemon), so SIGPIPE isn't a reliable
# enough leash.
our $EVENTS_PID;
# Set by the WINCH handler; cleared each time event_loop fetches the
# new terminal size. Caching matters because event_loop iterates on
# every keystroke AND every push event from the daemon (potentially
# many per second on a busy table), and tty_size() forks `stty size`.
# event_loop also reads unconditionally on entry — it runs fresh
# after every action (shell_attach return, etc.) and can't trust
# stale local state across calls.
our $WINCH_PENDING;

END {
    # ?1004l: disable focus reporting before the alt-screen flip so the
    # terminal isn't briefly emitting focus bytes into the user's shell
    # on the way out.
    print STDOUT "\e[?25h\e[?7h\e[?1004l\e[?1049l" if $IN_ALT;
    if (defined $SAVED_STTY) {
        system 'stty', $SAVED_STTY;
    }
    # Backstop only — main()'s teardown_events normally handles this.
    # If we reach END with $EVENTS_PID still set, something skipped
    # the eval/teardown path. No waitpid here: open('-|')'s implicit
    # close already does one when $m goes out of scope, so just kick
    # the child and let that close complete.
    kill 'TERM', $EVENTS_PID if defined $EVENTS_PID;
}

# ---------------------------------------------------------------------------
# Top-level flags forwarded to every `shpool` shell-out: --config-file,
# --log-file, --socket, -v. Mirrors shpool's global flag set; if shpool
# gains a new one, add it here so `shperl --socket /tmp/s2 -vv` keeps
# behaving like `shpool --socket /tmp/s2 -vv list / attach / kill`. Set
# once in main(); read by fetch_sessions, shell_attach, the kill
# shell-out, and the no-nest guard.
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
    { label => 'v', desc => 'vars', maps => [ [ ['byte', ord 'v'], 'Variables' ] ]},
    { label => 'q', desc => 'quit', maps => [
        [ ['byte', ord 'q'], 'Quit' ],
        [ ['byte', ord 'Q'], 'Quit' ],
        [ ['byte', 0x03],    'Quit' ],
    ]},
);

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
# shpool shell-outs
# ---------------------------------------------------------------------------
# Run @cmd, returning (ok, stdout, stderr). Every shpool invocation whose
# output shperl *reads* goes through here, so the daemon's diagnostics
# land in $err for the caller to park in the error slot instead of
# painting themselves over the alt screen ("could not connect to daemon"
# across the table).
#
# `shpool attach` is the deliberate exception: it takes over the
# terminal, and piping its stderr breaks shpool's own detach detection,
# so shell_attach hands it the real tty via system() instead.
#
# Both pipes are drained with select rather than one after the other:
# reading stdout to EOF first would wedge a child that filled the stderr
# pipe buffer meanwhile, and vice versa.
sub run_capture {
    my @cmd = @_;
    pipe(my $out_r, my $out_w) or die "pipe: $!";
    pipe(my $err_r, my $err_w) or die "pipe: $!";
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        close $out_r;
        close $err_r;
        open STDOUT, '>&', $out_w or POSIX::_exit(127);
        open STDERR, '>&', $err_w or POSIX::_exit(127);
        close $out_w;
        close $err_w;
        no warnings 'exec';
        exec { $cmd[0] } @cmd;
        POSIX::_exit(127);
    }
    close $out_w;
    close $err_w;

    my ($out, $err) = ('', '');
    my %live = (
        fileno($out_r) => [ $out_r, \$out ],
        fileno($err_r) => [ $err_r, \$err ],
    );
    while (%live) {
        my $rin = '';
        vec($rin, $_, 1) = 1 for keys %live;
        # select(2) writes the result mask into the input arg, so copy.
        my $rout   = $rin;
        my $nfound = select($rout, undef, undef, undef);
        if ($nfound < 0) {
            next if $!{EINTR};    # SIGWINCH while the action runs
            die "select: $!";
        }
        for my $fno (keys %live) {
            next unless vec($rout, $fno, 1);
            my ($fh, $dest) = @{ $live{$fno} };
            my $got = sysread($fh, my $chunk, 65536);
            if (!defined $got) { delete $live{$fno} unless $!{EINTR} }
            elsif ($got == 0)  { delete $live{$fno} }
            else               { $$dest .= $chunk }
        }
    }
    close $out_r;
    close $err_r;
    waitpid $pid, 0;
    return ($? == 0, $out, $err);
}

# Collapse a shell-out's stderr into one line for the error slot. The
# daemon's own complaint ("could not connect to daemon", "no session
# named 'foo'") beats a generic failure wherever it said anything;
# returns '' when it said nothing, so callers can fall back.
sub tidy_stderr {
    my $err = shift // '';
    $err =~ s/\s+/ /g;
    $err =~ s/^ //;
    $err =~ s/ $//;
    return $err;
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
    my ($ok, $json, $err) =
        run_capture('shpool', @SHPOOL_FLAGS, @extra, 'list', '--json');
    unless ($ok) {
        # The caller prefixes "shpool list: ", so die with the detail only.
        my $detail = tidy_stderr($err);
        die length $detail ? "$detail\n" : "`shpool list --json` failed\n";
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

# The daemon's template variables, via `shpool var list` (one
# "name<TAB>value" line each). Returns an arrayref of { name, value }
# sorted by name. Dies on spawn/exit failure like fetch_sessions.
sub fetch_vars {
    my ($ok, $raw, $err) = run_capture('shpool', @SHPOOL_FLAGS, 'var', 'list');
    unless ($ok) {
        # As in fetch_sessions: callers supply the "shpool var list: " prefix.
        my $detail = tidy_stderr($err);
        die length $detail ? "$detail\n" : "`shpool var list` failed\n";
    }
    return parse_var_list($raw // '');
}

# Parse `shpool var list` output (UTF-8 bytes, one "name<TAB>value" line
# each) into an arrayref of { name, value } sorted by name. Values are
# decoded to character strings so they line up with session names, which
# JSON::PP returns decoded; comparing a byte string against a character
# string would mis-handle a multibyte value (drop or mis-rank it).
sub parse_var_list {
    my $raw = shift // '';
    my @vars;
    for my $line (split /\n/, $raw) {
        next unless length $line;
        my ($name, $value) = split /\t/, $line, 2;
        push @vars, {
            name  => decode_utf8($name),
            value => decode_utf8($value // ''),
        };
    }
    return [ sort { $a->{name} cmp $b->{name} } @vars ];
}

# Variable names referenced by a session-name template: each {name}
# token, in first-seen order, de-duplicated. "{a}-{b}-{a}" -> ('a','b').
sub template_vars {
    my $tmpl = shift // '';
    my (@names, %seen);
    while ($tmpl =~ /\{(\w+)\}/g) {
        push @names, $1 unless $seen{$1}++;
    }
    return @names;
}

# Variables a template references that aren't in %known — the names a
# create-time prompt has to ask for. template_vars($name) minus the
# known keys, first-seen order preserved (so the prompt walks them in
# the order they appear in the name).
sub unknown_template_vars {
    my ($name, $known) = @_;
    return grep { !exists $known->{$_} } template_vars($name);
}

# Resolve a template against a { name => value } map: each {name}
# becomes its value; an unknown var is left as the literal {name}.
sub resolve_template {
    my ($tmpl, $vars) = @_;
    (my $out = $tmpl // '') =~ s/\{(\w+)\}/exists $vars->{$1} ? $vars->{$1} : "{$1}"/ge;
    return $out;
}

# Attachments across all sessions whose template references $var — the
# set that would re-dial if $var changed. Each hit records the session
# it currently resolves to, the template, and the attach-proc pid.
sub attachments_for_var {
    my ($sessions, $var) = @_;
    my @hits;
    for my $s (@$sessions) {
        for my $a (@{$s->{attachments} // []}) {
            my $tmpl = $a->{session_name_template} // '';
            next unless grep { $_ eq $var } template_vars($tmpl);
            push @hits, { session => $s->{name}, template => $tmpl, pid => $a->{pid} };
        }
    }
    return @hits;
}

# The { name => value } map fed to resolve_template / candidate_values.
# Built from real (set) variables only: synthetic unset rows carry no
# value, and slipping an `editor => ""` in here would collapse a literal
# {editor} in a preview to empty. The single source of that map, used
# wherever the vars view resolves a template.
sub resolution_map {
    return map { $_->{name} => $_->{value} } grep { !$_->{unset} } @_;
}

# Surface variables a template references but `var list` doesn't carry:
# union the template vars across every attachment of every session, drop
# the ones already set, and append a synthetic { name, unset => 1 } row
# for each remainder. The result is re-sorted by name so set and unset
# rows interleave alphabetically, matching the list view's ordering.
#
# Templates live only on attached sessions (attachments[]), so a var
# referenced solely by a detached session contributes nothing — same
# scope as attachments_for_var. A var that is both set and referenced
# stays a single (set) row; a var referenced by several templates yields
# one unset row.
sub merge_unset_vars {
    my ($var_list, $sessions) = @_;
    my %set = map { $_->{name} => 1 } @$var_list;
    my (%referenced);
    for my $s (@$sessions) {
        for my $a (@{$s->{attachments} // []}) {
            $referenced{$_} = 1 for template_vars($a->{session_name_template} // '');
        }
    }
    my @merged = @$var_list;
    for my $name (keys %referenced) {
        next if $set{$name};
        push @merged, { name => $name, unset => 1 };
    }
    return [ sort { $a->{name} cmp $b->{name} } @merged ];
}

# Candidate values for a variable: values that, substituted for $target
# (other variables pinned to their current values in $vars_map), make one
# of $target's templates resolve to a session name that currently exists.
# $vars_map is the { name => value } hash resolve_template consumes.
#
# Templates come only from currently-attached sessions (attachments[]),
# but the match scans ALL session names — a detached session still exists
# by name and is a valid re-dial target. The capture is a prefix/suffix
# strip (length-checked substr, never index by prefix length), so it's
# byte-safe on multibyte names. Returns the current value first, then the
# harvested captures, de-duplicated.
sub candidate_values {
    my ($sessions, $vars_map, $target) = @_;
    my $current = $vars_map->{$target} // '';

    # Distinct templates (from attachments) that mention {$target}.
    my (@templates, %tseen);
    for my $s (@$sessions) {
        for my $a (@{$s->{attachments} // []}) {
            my $tmpl = $a->{session_name_template} // '';
            next unless grep { $_ eq $target } template_vars($tmpl);
            push @templates, $tmpl unless $tseen{$tmpl}++;
        }
    }

    my @names = map { $_->{name} } @$sessions;

    my (@cands, %seen);
    $seen{$current} = 1;
    push @cands, $current;

    for my $tmpl (@templates) {
        # Split into literal / {var} tokens (odd indices are var tokens),
        # matching resolve_template's \{\w+\} rule. Locate the single
        # {$target} token; skip the template if it appears 0 or 2+ times.
        my @parts = split /(\{\w+\})/, $tmpl, -1;
        my @target_at = grep { $parts[$_] eq "{$target}" } 0 .. $#parts;
        next if @target_at != 1;
        my $ti = $target_at[0];

        # Pin co-vars: everything but the target token, resolved against
        # $vars_map (unknown co-var stays literal {name}, per
        # resolve_template), collapsing to prefix + {target} + suffix.
        my $prefix = resolve_template(join('', @parts[0 .. $ti - 1]),    $vars_map);
        my $suffix = resolve_template(join('', @parts[$ti + 1 .. $#parts]), $vars_map);

        for my $n (@names) {
            # Strip $prefix from the front and $suffix from the back; the
            # remainder is the captured value. Length-checked so we never
            # over-read or split a multibyte char.
            next if length($n) < length($prefix) + length($suffix);
            next if substr($n, 0, length $prefix) ne $prefix;
            next if length($suffix)
                && substr($n, -length($suffix)) ne $suffix;
            my $cap = substr($n, length($prefix),
                length($n) - length($prefix) - length($suffix));
            next unless length $cap;          # empty capture dropped
            next if $seen{$cap}++;
            push @cands, $cap;
        }
    }
    return @cands;
}

# Filter + rank candidates against a query. Keep candidates whose
# ASCII-lowercased form has the ASCII-lowercased query as a subsequence;
# order by a total key: (1) exact match, (2) contiguous (substring)
# before scattered, (3) earliest first-match char index, (4) fewer
# characters, (5) harvest index. An empty query keeps everything in
# harvest order. All comparisons are on folded character forms, so the
# ranking is identical regardless of byte width.
sub filter_rank {
    my ($cands, $query) = @_;
    return @$cands unless length $query;

    my $fold = sub { (my $s = $_[0]) =~ tr/A-Z/a-z/; $s };
    my $fq    = $fold->($query);
    my @fqc   = split //, $fq;

    my @ranked;
    for my $i (0 .. $#$cands) {
        my $cand = $cands->[$i];
        my $fc   = $fold->($cand);
        my @fcc  = split //, $fc;

        # Subsequence test on folded chars; also record the index of the
        # first candidate char equal to the first query char.
        my $first = -1;
        my $qi = 0;
        for my $ci (0 .. $#fcc) {
            $first = $ci if $first < 0 && $fcc[$ci] eq $fqc[0];
            $qi++ if $qi <= $#fqc && $fcc[$ci] eq $fqc[$qi];
        }
        next unless $qi == @fqc;              # not a subsequence

        my $exact      = $fc eq $fq ? 0 : 1;
        my $contiguous = index($fc, $fq) >= 0 ? 0 : 1;
        push @ranked, {
            cand  => $cand,
            key   => [ $exact, $contiguous, $first, scalar(@fcc), $i ],
        };
    }
    my @sorted = sort {
        my ($x, $y) = ($a->{key}, $b->{key});
        $x->[0] <=> $y->[0]
          || $x->[1] <=> $y->[1]
          || $x->[2] <=> $y->[2]
          || $x->[3] <=> $y->[3]
          || $x->[4] <=> $y->[4]
    } @ranked;
    return map { $_->{cand} } @sorted;
}

# Latest timestamp on the session — includes started_at so a
# brand-new session sorts as recent even before any connect/detach.
sub last_touched_ms {
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
        # stale_select is the source of truth for "no valid selection"
        # (rather than $selected having a sentinel value): set when a
        # refresh removes the previously-selected session, cleared by
        # navigation or by ack. Decoupling from $selected means a
        # concurrent session creation can't quietly revalidate a stale
        # index.
        stale_select => 0,
        mode         => 'normal',    # normal | create | create_vars | kill | confirm_force | vars
        mode_data    => '',          # create: partial name; kill/confirm_force: target name
        # create_vars mode: per-var prompt state for a new session whose
        # name references vars not yet set. Populated by event_loop when it
        # intercepts a ['create', name] whose name has unknown vars; undef
        # otherwise. { name, vars (ordered unknowns), idx, input,
        # collected ([[var,val],...]), set_vars ({name=>value} of the
        # already-set vars, for the live name preview) }.
        var_prompt   => undef,
        error        => undef,
        parser_state => 'normal',    # normal | esc | esc_bracket
        events_pid   => undef,       # `shpool events` child pid, or undef
        events_fh    => undef,       # read end of its stdout pipe, or undef
        # vars mode (browsing/editing the daemon's template variables),
        # grouped under one key so the view's state lives together.
        # While editing, the value selector holds a two-slot edit state:
        # `field` is the text Enter applies; `filter` is `field` as of the
        # last typing keystroke (frozen while arrowing) and is what the
        # `cands` list filters by; `highlight` indexes the filtered list.
        vars         => {
            list      => [],   # [ { name, value }, ... ] sorted by name
            sel       => 0,    # selected index into list
            edit      => 0,    # 1 while editing a value
            field     => '',   # editable text; the value Enter applies
            filter    => '',   # list filter: field as of the last keystroke
            cands     => [],   # harvested candidate values (fixed per edit)
            highlight => 0,    # index into the filtered (shown) list
        },
    };
}

sub model_selected_name {
    my $m = shift;
    return undef if $m->{stale_select};
    return undef unless @{$m->{sessions}};
    return undef if $m->{selected} >= @{$m->{sessions}};
    return $m->{sessions}[$m->{selected}]{name};
}

sub model_select_next {
    my $m = shift;
    return unless @{$m->{sessions}};
    $m->{stale_select} = 0;
    $m->{selected} = ($m->{selected} + 1) % scalar @{$m->{sessions}};
}

sub model_select_prev {
    my $m = shift;
    return unless @{$m->{sessions}};
    $m->{stale_select} = 0;
    if ($m->{selected} == 0) {
        $m->{selected} = $#{$m->{sessions}};
    } else {
        $m->{selected}--;
    }
}

# Drop the selection without raising stale_select. Setting $selected
# out of bounds is the model invariant for "no selection" when the
# caller knows the absence is expected (e.g. a user-initiated kill
# of the last session); stale_select is reserved for unexpected
# disappearances where the user should be alerted.
sub model_clear_selection {
    my $m = shift;
    $m->{selected} = scalar @{$m->{sessions}};
}

# Move selection off $name to the neighbor (next, or previous if it
# was last). If $name is the only session, clear instead. No-op if
# $name isn't currently selected. Used before a deliberate kill so
# the post-kill refresh's model_refresh finds prev_name (the
# neighbor, or undef) in the new list and doesn't flag stale_select
# on what was a user-initiated removal.
sub model_advance_off {
    my ($m, $name) = @_;
    my $current = model_selected_name($m);
    return unless defined $current && $current eq $name;
    my @sess = @{$m->{sessions}};
    my ($idx) = grep { $sess[$_]{name} eq $name } 0 .. $#sess;
    return unless defined $idx;
    if (@sess == 1) {
        model_clear_selection($m);
        return;
    }
    $m->{selected} = $idx == $#sess ? $idx - 1 : $idx + 1;
}

# Replace session list, sorting newest-active first and preserving the
# previous selection by name where possible. On miss, flag the model
# as stale and park an error — the user has to ack (any keystroke
# clears the error; navigation clears stale_select; Enter/d are
# consumed as ack without acting on the new occupant of the slot).
sub model_refresh {
    my ($m, $new) = @_;
    my @sorted = sort { last_touched_ms($b) <=> last_touched_ms($a) } @$new;
    my $prev_name = model_selected_name($m);
    my $prev_idx  = $m->{selected};
    $m->{sessions} = \@sorted;
    if (defined $prev_name) {
        for my $i (0 .. $#sorted) {
            if ($sorted[$i]{name} eq $prev_name) {
                $m->{selected}     = $i;
                $m->{stale_select} = 0;
                return;
            }
        }
        # Previously-selected session is gone.
        $m->{stale_select} = 1;
        model_set_error($m, "session '$prev_name' is gone");
    }
    # Skip the clamp on an empty list — there's no valid index, and
    # model_select_next/prev (the other write-paths) likewise leave
    # $selected untouched in that case.
    return unless @sorted;
    $m->{selected} = $prev_idx > $#sorted ? $#sorted : $prev_idx;
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
    # Skip when events are flowing — the model is already current.
    refresh_sessions($m) if $focus_gained && !defined $m->{events_fh};
    return undef unless @keep;

    # Keep the error visible across the first keystroke when we're in
    # a stale-selection state — process_normal then consumes it as
    # acknowledgment (see comment there) and clears both flag + error.
    $m->{error} = undef unless $m->{stale_select};
    return process_normal(\@keep, $m)                          if $m->{mode} eq 'normal';
    return process_create_input(\@keep, $m)                    if $m->{mode} eq 'create';
    return process_create_vars_input(\@keep, $m)               if $m->{mode} eq 'create_vars';
    return process_yn_confirm(\@keep, $m, 'kill')              if $m->{mode} eq 'kill';
    return process_yn_confirm(\@keep, $m, 'attach_force')      if $m->{mode} eq 'confirm_force';
    return process_vars_input(\@keep, $m)                      if $m->{mode} eq 'vars';
    return undef;
}

# Normal-mode key handlers. Each takes the model and returns either
# an action arrayref (propagated out, alt-screen tears down) or undef
# (mutate state and continue). Handlers that change mode (NewSession,
# KillSession, Enter's force-promote) return undef but leave
# $m->{mode} != 'normal'; the dispatcher stops iterating in that case
# so the rest of the burst doesn't get run through normal-mode logic.
my %NORMAL_HANDLERS = (
    Up   => sub { model_select_prev($_[0]); undef },
    Down => sub { model_select_next($_[0]); undef },
    Enter => sub {
        my $m = shift;
        my $name = model_selected_name($m);
        return undef unless defined $name;
        # Live-check the attached flag at keypress time. The cached
        # value updates once per keystroke, which goes stale fast if
        # the user detaches elsewhere and then sits on the shperl UI
        # without pressing anything. With events subscribed, the
        # cache stays current via the event-driven refresh, so this
        # pre-flight is redundant.
        refresh_sessions($m) unless defined $m->{events_fh};
        my ($sess) = grep { $_->{name} eq $name } @{$m->{sessions}};
        return [ 'attach', $name ] if !$sess;    # let run_tui report "gone"
        if ($sess->{attached}) {
            $m->{mode}      = 'confirm_force';
            $m->{mode_data} = $name;
            return undef;
        }
        return [ 'attach', $name ];
    },
    NewSession => sub {
        my $m = shift;
        $m->{mode}      = 'create';
        $m->{mode_data} = '';
        return undef;
    },
    KillSession => sub {
        my $m = shift;
        my $name = model_selected_name($m);
        return undef unless defined $name;
        $m->{mode}      = 'kill';
        $m->{mode_data} = $name;
        return undef;
    },
    EnsureDaemon => sub { [ 'ensure_daemon' ] },
    Variables    => sub { enter_vars_mode($_[0]); undef },
    Quit         => sub { [ 'quit' ] },
);

# Enter the template-variable view: snapshot `shpool var list` into the
# model and reset the cursor. On a list failure, park the error and stay
# in normal mode rather than opening an empty view.
sub enter_vars_mode {
    my $m = shift;
    my $vars = eval { fetch_vars() };
    if ($@) {
        (my $e = $@) =~ s/^\s+|\s+$//g;
        model_set_error($m, "shpool var list: $e");
        return;
    }
    $m->{vars}{list}  = merge_unset_vars($vars, $m->{sessions});
    $m->{vars}{sel}   = 0;
    vars_edit_clear($m);
    $m->{mode}   = 'vars';
}

# Re-derive the displayed variable list — set rows ∪ the unset rows the
# current sessions reference — while keeping the cursor on the same
# variable by name. The list is a function of (real vars, sessions), so
# anything that changes either input while we're in the view (a `var
# set`, a session refresh) runs through here. The cursor moves by name
# because the merge re-sorts and a set can both add and remove rows
# (promoting an unset row to a set one, shifting indices); on no match
# (only a concurrent external `var unset` can drop the selected name)
# clamp to the last row. Filters out any prior synthetic rows first so
# they never feed back into the union as if they were set.
sub remerge_vars {
    my $m = shift;
    my $cur = $m->{vars}{list};
    # Guard the index read so an empty or out-of-bounds selection can't
    # autovivify a phantom row into the array via the ->{name} deref.
    my $prev = $m->{vars}{sel} <= $#$cur ? $cur->[$m->{vars}{sel}]{name} : undef;
    my @real = grep { !$_->{unset} } @$cur;
    $m->{vars}{list} = merge_unset_vars(\@real, $m->{sessions});
    my ($idx);
    ($idx) = grep { $m->{vars}{list}[$_]{name} eq $prev }
        0 .. $#{$m->{vars}{list}} if defined $prev;
    $m->{vars}{sel} = defined $idx ? $idx
        : ($#{$m->{vars}{list}} < 0 ? 0 : $#{$m->{vars}{list}});
}

sub leave_vars_mode {
    my $m = shift;
    $m->{mode}   = 'normal';
    vars_edit_clear($m);
}

# Reset the value-selector slots to the not-editing state.
sub vars_edit_clear {
    my $m = shift;
    $m->{vars}{edit}      = 0;
    $m->{vars}{field}     = '';
    $m->{vars}{filter}    = '';
    $m->{vars}{cands}     = [];
    $m->{vars}{highlight} = 0;
}

# Open the value selector on the selected variable: harvest candidates
# from existing session names, start with an empty field/filter (the
# current value is just the highlighted row, not prefilled text), and
# highlight the first row.
sub vars_edit_start {
    my $m = shift;
    return unless @{$m->{vars}{list}};
    my %vmap = resolution_map(@{$m->{vars}{list}});
    my $name = $m->{vars}{list}[$m->{vars}{sel}]{name};
    $m->{vars}{edit}      = 1;
    $m->{vars}{field}     = '';
    $m->{vars}{filter}    = '';
    $m->{vars}{cands}     = [ candidate_values($m->{sessions}, \%vmap, $name) ];
    $m->{vars}{highlight} = 0;
}

# The visible candidate list: cands filtered/ranked by the current
# filter. The list Up/Down navigates and that render_vars windows.
sub vars_shown {
    my $m = shift;
    return filter_rank($m->{vars}{cands}, $m->{vars}{filter});
}

sub vars_select {
    my ($m, $dir) = @_;
    my $n = scalar @{$m->{vars}{list}};
    return unless $n;
    $m->{vars}{sel} = ($m->{vars}{sel} + $dir) % $n;
}

sub process_normal {
    my ($tokens, $m) = @_;
    for my $t (@$tokens) {
        my $key = token_to_key($t);
        if ($m->{stale_select}) {
            # Selection went stale (a refresh removed the highlighted
            # session). Consume this token as acknowledgment — clear
            # the flag and the error so they don't stick further. For
            # Enter/d (act-on-selection), the user is presumed to be
            # attempting the original action; we don't want it landing
            # on whatever happens to be at the same row now, so skip
            # to the next token without dispatching.
            $m->{stale_select} = 0;
            $m->{error}        = undef;
            next if $key eq 'Enter' || $key eq 'KillSession';
        }
        my $handler = $NORMAL_HANDLERS{$key} or next;  # 'Other' — ignore
        my $action = $handler->($m);
        return $action if $action;
        # Stop iterating once a handler has switched out of normal
        # mode — subsequent tokens belong to the new mode's handler.
        return undef if $m->{mode} ne 'normal';
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
                # Dup-check in the pure handler, before any var detection:
                # a name that already exists short-circuits to an error
                # with no prompt and no var sets. `shpool attach` is
                # create-or-attach, so without this a duplicate name would
                # silently attach. (The create action-handler repeats this
                # check post-teardown as a backstop.)
                if (grep { $_->{name} eq $name } @{$m->{sessions}}) {
                    model_set_error($m, "session '$name' already exists");
                    return undef;
                }
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

# Create-time variable prompt. Walks $m->{var_prompt}{vars} (the unknown
# vars referenced by the new session's name, in template order), one at a
# time: printable/Backspace edit the current `input`; Enter pushes
# (current var, input) to `collected` when non-empty (an empty entry
# skips that var — it stays unset, surfaced later by the vars view) and
# advances `idx`. Once every var has been visited, drop to normal mode
# (so a failed apply's error isn't hidden behind this bottom-bar label)
# and emit ['create_vars', name, \@collected]; event_loop sets each pair
# then reuses the create→attach path. Esc/^C cancel the whole prompt
# (nothing is set, no session is created).
sub process_create_vars_input {
    my ($tokens, $m) = @_;
    my $vp = $m->{var_prompt};
    for my $t (@$tokens) {
        if ($t->[0] eq 'bare_esc') {
            $m->{mode}        = 'normal';
            $m->{var_prompt}  = undef;
            return undef;
        }
        next if $t->[0] eq 'csi';    # arrow keys etc. — silently ignored
        my $b = $t->[1];
        if ($b == 0x03) {
            $m->{mode}        = 'normal';
            $m->{var_prompt}  = undef;
            return undef;
        }
        elsif ($b == 0x0d || $b == 0x0a) {
            push @{$vp->{collected}}, [ $vp->{vars}[$vp->{idx}], $vp->{input} ]
                if length $vp->{input};
            $vp->{idx}++;
            if ($vp->{idx} == @{$vp->{vars}}) {
                # Drop to normal before emitting so an apply failure's
                # error (parked by event_loop) isn't outranked by this
                # prompt's bottom-bar label.
                my $name      = $vp->{name};
                my $collected = $vp->{collected};
                $m->{mode}       = 'normal';
                $m->{var_prompt} = undef;
                return [ 'create_vars', $name, $collected ];
            }
            $vp->{input} = '';
        }
        elsif ($b == 0x7f || $b == 0x08) {
            $vp->{input} = substr($vp->{input}, 0, -1) if length $vp->{input};
        }
        elsif ($b >= 0x20 && $b <= 0x7e) {    # printable (values may hold spaces)
            $vp->{input} .= chr($b);
        }
    }
    return undef;
}

# Template-variable view. Two sub-states keyed off vars.edit:
#   browsing — j/k move the cursor; e/Enter open the value selector; Esc/q
#              (or ^C) return to the session list.
#   editing  — the value selector. Up/Down move the highlight within the
#              candidate list (copying the highlighted value into `field`,
#              leaving `filter` frozen so the list stays put); printable
#              bytes / Backspace edit `field`, refresh `filter` from it,
#              and reset the highlight to the top; Enter commits a
#              ['var_set', name, value] action (run inline by event_loop,
#              which re-fetches vars + sessions so the preview updates) —
#              applying `field`, or the highlighted candidate when `field`
#              is empty; Esc/^C abandon the edit.
sub process_vars_input {
    my ($tokens, $m) = @_;
    for my $t (@$tokens) {
        if ($m->{vars}{edit}) {
            if ($t->[0] eq 'bare_esc') { vars_edit_clear($m); next; }
            # Arrows move the highlight and copy the highlighted candidate
            # into the field; the filter is left frozen so the list stays
            # stable while arrowing. Handled before the byte path so CSI
            # final bytes are never typed into the field. Other CSI
            # sequences are consumed.
            if ($t->[0] eq 'csi') {
                if ($t->[1] == ord 'A' || $t->[1] == ord 'B') {
                    my @shown = vars_shown($m);
                    if (@shown) {
                        my $dir = $t->[1] == ord 'B' ? 1 : -1;
                        my $h   = $m->{vars}{highlight} + $dir;
                        $h = 0          if $h < 0;
                        $h = $#shown    if $h > $#shown;
                        $m->{vars}{highlight} = $h;
                        $m->{vars}{field}     = $shown[$h];
                    }
                }
                next;
            }
            my $b = $t->[1];
            if ($b == 0x03) { vars_edit_clear($m); next; }
            elsif ($b == 0x0d || $b == 0x0a) {
                my $name  = $m->{vars}{list}[$m->{vars}{sel}]{name};
                my @shown = vars_shown($m);
                # Empty field => apply the highlighted row (= the current
                # value, since an empty filter shows it first); otherwise
                # apply the literal field (no dead zone — `xm` is applied
                # as `xm` even while `xmr` is shown).
                my $value = length $m->{vars}{field}
                    ? $m->{vars}{field}
                    : ($shown[$m->{vars}{highlight}] // '');
                return [ 'var_set', $name, $value ];
            }
            elsif ($b == 0x7f || $b == 0x08) {
                $m->{vars}{field} = substr($m->{vars}{field}, 0, -1)
                    if length $m->{vars}{field};
                $m->{vars}{filter}    = $m->{vars}{field};
                $m->{vars}{highlight} = 0;
            }
            elsif ($b >= 0x20 && $b <= 0x7e) {    # printable (values may hold spaces)
                $m->{vars}{field}    .= chr($b);
                $m->{vars}{filter}    = $m->{vars}{field};
                $m->{vars}{highlight} = 0;
            }
            next;
        }
        # browsing
        if ($t->[0] eq 'bare_esc') { leave_vars_mode($m); return undef; }
        if ($t->[0] eq 'csi') {
            vars_select($m,  1) if $t->[1] == ord 'B';
            vars_select($m, -1) if $t->[1] == ord 'A';
            next;
        }
        my $b = $t->[1];
        if ($b == 0x03 || $b == ord 'q') { leave_vars_mode($m); return undef; }
        elsif ($b == ord 'j' || $b == ord 'J') { vars_select($m,  1); }
        elsif ($b == ord 'k' || $b == ord 'K') { vars_select($m, -1); }
        elsif ($b == 0x0d || $b == 0x0a || $b == ord 'e') {
            vars_edit_start($m);
        }
        # other keys ignored — stay in the view
    }
    return undef;
}

# Yes/no confirm modals (kill, confirm_force) share their key
# handling: y/Y commits with $verb as the action; n/N/Esc/^C cancel;
# csi (arrows) and other unmapped keys are ignored so a fat-finger
# doesn't silently dismiss the prompt. Matches process_create_input's
# "specific keys only" style — only the keys advertised in the
# bottom-bar copy have effects.
sub process_yn_confirm {
    my ($tokens, $m, $verb) = @_;
    for my $t (@$tokens) {
        next if $t->[0] eq 'csi';
        if ($t->[0] eq 'bare_esc') {
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return undef;
        }
        my $b = $t->[1];
        if ($b == ord 'y' || $b == ord 'Y') {
            my $name = $m->{mode_data};
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return [ $verb, $name ];
        }
        if ($b == 0x03 || $b == ord 'n' || $b == ord 'N') {
            $m->{mode}      = 'normal';
            $m->{mode_data} = '';
            return undef;
        }
        # other keys ignored — stay in modal
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
    push_hints($l, [ [ 'ret', 'create' ], [ 'esc', 'cancel' ] ]);
    label_push_plain($l, ')');
    return $l;
}

# Create-time variable prompt bottom bar: which var is being asked for,
# the value typed so far, and a live preview of the session name as it
# resolves under the values entered so far. The preview map is the
# already-set vars, plus every value collected on prior prompts, plus the
# current var bound to the in-progress input. Vars still to be prompted
# are deliberately left out of the map so resolve_template renders them as
# the literal {name} — folding them in empty would collapse a {future}-x
# template to -x, mis-previewing the eventual name.
sub create_vars_label {
    my $vp = shift;
    my $var = $vp->{vars}[$vp->{idx}];
    my %map = %{ $vp->{set_vars} };
    $map{$_->[0]} = $_->[1] for @{$vp->{collected}};
    $map{$var}    = $vp->{input};
    my $preview = resolve_template($vp->{name}, \%map);
    my $last = $vp->{idx} == $#{$vp->{vars}};

    my $l = label_new();
    label_push_plain($l, "set value for ");
    label_push_key($l,   $var);
    label_push_plain($l, ': ');
    label_push_key($l,   $vp->{input});
    label_push_plain($l, "_   ");
    label_push_plain($l, $preview);
    label_push_plain($l, '   (');
    push_hints($l, [ [ 'ret', $last ? 'create' : 'next' ], [ 'esc', 'cancel' ] ]);
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
    push_hints($l, [ [ 'y', 'confirm' ], [ 'n', 'cancel' ] ]);
    label_push_plain($l, ')');
    return $l;
}

sub confirm_force_label {
    my $name = shift;
    my $l = label_new();
    label_push_key($l,   qq{"$name"});
    label_push_plain($l, ' already attached. force-attach?   (');
    push_hints($l, [ [ 'y', 'force' ], [ 'n', 'cancel' ] ]);
    label_push_plain($l, ')');
    return $l;
}

sub vars_title_label {
    my $m = shift;
    my $n = scalar @{$m->{vars}{list}};
    my $l = label_new();
    label_push_key($l, "variables ($n)");
    return $l;
}

# Vars-view bottom bar. The value-entry line outranks an error (same
# rule as the session view's modals); otherwise show the key hints.
sub vars_bottom_label {
    my $m = shift;
    if ($m->{vars}{edit}) {
        my $l = label_new();
        label_push_plain($l, 'set ');
        label_push_key($l,   $m->{vars}{list}[$m->{vars}{sel}]{name});
        label_push_plain($l, ' = ');
        label_push_key($l,   $m->{vars}{field});
        label_push_plain($l, '_   (');
        push_hints($l, [ [ 'ret', 'apply' ], [ 'esc', 'cancel' ] ]);
        label_push_plain($l, ')');
        return $l;
    }
    return error_label($m->{error}) if defined $m->{error};
    my $l = label_new();
    push_hints($l, [ [ 'j/k', 'select' ], [ 'e', 'set value' ], [ 'esc', 'back' ] ]);
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

# Milliseconds until format_age would render a different string for a
# value currently $age_ms old — the distance to the next bucket edge.
# Mirrors format_age's thresholds so the two stay in lockstep.
sub ms_until_age_changes {
    my $age_ms = shift;
    my $secs = int($age_ms / 1000);
    return 5000     - $age_ms              if $secs < 5;      # "now" -> "5s"
    return 1000     - $age_ms % 1000       if $secs < 60;     # next second
    return 60000    - $age_ms % 60000      if $secs < 3600;   # next minute
    return 3600000  - $age_ms % 3600000    if $secs < 86400;  # next hour
    return 86400000 - $age_ms % 86400000;                     # next day
}

# Milliseconds until the soonest on-screen relative-age string would
# change, or undef when there's nothing to tick (empty list). Drives the
# select timeout so the "created"/"active" columns advance on their own
# while the table is idle, without waking any more often than the
# coarsest visible unit needs. Computed over every session — cheap, and
# the youngest sets the cadence whether or not it's scrolled into view.
# Floored at 100ms so a cluster of sessions straddling a boundary can't
# provoke a flurry of sub-frame wakes.
sub next_render_delay_ms {
    my ($m, $now_ms) = @_;
    my $min;
    for my $s (@{$m->{sessions}}) {
        for my $then ($s->{started_at_unix_ms} // 0, last_touched_ms($s)) {
            my $age = $now_ms > $then ? $now_ms - $then : 0;
            my $d   = ms_until_age_changes($age);
            $min = $d if !defined $min || $d < $min;
        }
    }
    return undef unless defined $min;
    return $min < 100 ? 100 : $min;
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

# Widest session name, floored at len("name") so the header line is
# always at least as wide as its own label.
sub name_column_width {
    my $sessions = shift;
    my $w = 4;     # len("name")
    for my $s (@$sessions) {
        my $len = length $s->{name};
        $w = $len if $len > $w;
    }
    return $w;
}

sub header_row {
    my ($w, $name_width) = @_;
    my $gap = ' ' x $COL_GAP;
    my $header = clip_plain(
        sprintf("  %-*s%s%-*s%s%-*s",
            $name_width,           'name',
            $gap,
            length($COL_CREATED),  $COL_CREATED,
            $gap,
            length($COL_ACTIVE),   $COL_ACTIVE),
        $w,
    );
    return sprintf("%s%s%-*s%s\r\n",
        $SGR_BAR_BG, $SGR_AMBER_DIM, $w, $header, $SGR_RESET);
}

# Format one row of the session list. 2-char prefix is [attached
# marker][selected arrow]: asterisk for sessions attached elsewhere
# (so the user sees the state without having to hit Enter and get
# the pre-flight rejection), '>' for the highlighted row. ASCII so
# we don't depend on the terminal's locale/font.
sub session_row {
    my ($s, $is_selected, $name_width, $now, $w) = @_;
    my $gap     = ' ' x $COL_GAP;
    my $dot     = $s->{attached} ? '*' : ' ';
    my $arrow   = $is_selected   ? '>' : ' ';
    my $created = format_age($now, $s->{started_at_unix_ms} // 0);
    my $active  = format_age($now, last_touched_ms($s));
    my $text = clip_plain(
        sprintf("%s%s%-*s%s%-*s%s%-*s",
            $dot, $arrow,
            $name_width,           $s->{name},
            $gap,
            length($COL_CREATED),  $created,
            $gap,
            length($COL_ACTIVE),   $active),
        $w,
    );
    return $is_selected
        ? sprintf("%s%-*s%s\r\n", $SGR_SELECTED, $w, $text, $SGR_RESET)
        : sprintf("%-*s\r\n", $w, $text);
}

# Bottom-bar contents. Modal prompts outrank errors: the user is
# mid-interaction (typing a name, confirming a kill, ...) and
# replacing their prompt with an error message — including one
# raised by a background refresh about an unrelated session — hides
# their typed input and turns the next Enter into a commit-while-
# blind. The error stays on the model and surfaces the next time
# we're in normal mode.
sub bottom_bar_label {
    my $m = shift;
    return create_input_label($m->{mode_data})  if $m->{mode} eq 'create';
    return create_vars_label($m->{var_prompt})  if $m->{mode} eq 'create_vars';
    return confirm_force_label($m->{mode_data}) if $m->{mode} eq 'confirm_force';
    return confirm_kill_label($m->{mode_data})  if $m->{mode} eq 'kill';
    return error_label($m->{error})             if defined $m->{error};
    return normal_bindings_label();
}

sub render {
    my ($m, $w, $h) = @_;
    return render_vars($m, $w, $h) if $m->{mode} eq 'vars';
    my $out = "\e[2J\e[H";                              # clear + home
    $out .= render_bar($w, title_label($m), 'center');
    my $name_width = name_column_width($m->{sessions});
    $out .= header_row($w, $name_width);
    if (!@{$m->{sessions}}) {
        $out .= "  (no sessions)\r\n";
    } else {
        my $now = now_unix_ms();
        my $max_visible = $h - $CHROME_LINES;
        $max_visible = 0 if $max_visible < 0;
        my ($start, $end) = viewport(
            scalar @{$m->{sessions}}, $m->{selected}, $max_visible);
        for my $i ($start .. $end - 1) {
            my $is_selected = !$m->{stale_select} && $i == $m->{selected};
            $out .= session_row(
                $m->{sessions}[$i], $is_selected, $name_width, $now, $w);
        }
    }
    $out .= render_bar($w, bottom_bar_label($m), 'left');
    return $out;
}

# Template-variable view: the variable list with a cursor, plus a live
# preview of which attachments the selected variable governs — and,
# while editing, what each would re-dial to under the typed value. This
# is the payoff of list --json's attachments[].session_name_template:
# the resolved session name alone can't tell you which variable spawned
# it, so without the template there's nothing to preview.
sub render_vars {
    my ($m, $w, $h) = @_;
    my $out = "\e[2J\e[H";
    $out .= render_bar($w, vars_title_label($m), 'center');

    my $body_rows = $h - 2;             # title bar + bottom bar
    $body_rows = 0 if $body_rows < 0;

    my $vlist = $m->{vars}{list};
    my @lines;
    if (!@$vlist) {
        push @lines, '  (no variables — shpool var set NAME VALUE)';
    } else {
        push @lines, vars_list_lines($m, $w);

        my $sel    = $vlist->[$m->{vars}{sel}];
        my %vmap   = resolution_map(@$vlist);

        if ($m->{vars}{edit}) {
            # Layout C: variable list, then the windowed candidate list,
            # then the re-dial preview pointed at the highlighted
            # candidate (or, when nothing matches the filter, the literal
            # field). Window the candidate list into whatever rows the
            # variable list + preview block leave free, so the preview is
            # never crowded out; the body still top-clips as a backstop.
            my @shown   = vars_shown($m);
            my $target  = @shown ? $shown[$m->{vars}{highlight}] : $m->{vars}{field};
            my @preview = vars_preview_lines($m, $sel, \%vmap, $target, $w);
            my $reserved = scalar(@lines)        # variable list
                         + 1                      # candidate header
                         + scalar(@preview);      # blank + preview block
            my $rows = $body_rows - $reserved;
            $rows = 3 if $rows < 3;               # small floor; clip backstops
            push @lines, vars_cand_lines($m, \@shown, $rows, $w);
            push @lines, @preview;
        } else {
            # Browsing: resolve the preview against current values.
            push @lines, vars_preview_lines($m, $sel, \%vmap, undef, $w);
        }
    }

    if    ($body_rows <= 0)     { @lines = (); }
    elsif (@lines > $body_rows) { @lines = @lines[0 .. $body_rows - 1]; }
    $out .= "$_\r\n" for @lines;

    $out .= render_bar($w, vars_bottom_label($m), 'left');
    return $out;
}

# The variable list: one row per variable, the selected row marked and
# reverse-video, each annotated with how many attachments it governs. An
# unset row — a variable a template references but `var list` doesn't
# carry — drops the `= value` for a dimmed (unset) in the value column;
# setting it (e/Enter) creates the variable.
sub vars_list_lines {
    my ($m, $w) = @_;
    my $vlist = $m->{vars}{list};
    my $nw = 0;
    for my $v (@$vlist) { my $n = length $v->{name}; $nw = $n if $n > $nw; }
    my @lines;
    for my $i (0 .. $#$vlist) {
        my $v     = $vlist->[$i];
        my $sel   = $i == $m->{vars}{sel};
        my $arrow = $sel ? '>' : ' ';
        my $count = scalar attachments_for_var($m->{sessions}, $v->{name});
        my $tail  = sprintf('   (%d session%s)', $count, $count == 1 ? '' : 's');
        my $row   = $v->{unset}
            ? sprintf(' %s %-*s   (unset)%s', $arrow, $nw, $v->{name}, $tail)
            : sprintf(' %s %-*s = %s%s',      $arrow, $nw, $v->{name}, $v->{value}, $tail);
        $row = clip_plain($row, $w);
        my $line = $sel
            ? sprintf('%s%-*s%s', $SGR_SELECTED, $w, $row, $SGR_RESET)
            : $row;
        # Dim the (unset) marker as a post-pad substitution so the
        # width/clip accounting above stays on plain text. On the
        # selected row, re-assert reverse-video after the marker's reset
        # so the dim doesn't bleed into the rest of the row.
        if ($v->{unset}) {
            my $dimmed = $SGR_AMBER_DIM . '(unset)' . $SGR_RESET
                       . ($sel ? $SGR_SELECTED : '');
            $line =~ s/\Q(unset)\E/$dimmed/;
        }
        push @lines, $line;
    }
    return @lines;
}

# The candidate list while editing: a header plus the visible window of
# @$shown (sized to $rows around the highlight via the shared viewport
# helper), the highlighted row marked and reverse-video.
sub vars_cand_lines {
    my ($m, $shown, $rows, $w) = @_;
    my @lines = ('  candidate values:');
    if (!@$shown) {
        push @lines, '    (no matching session names)';
        return @lines;
    }
    $rows = 1 if $rows < 1;
    my ($start, $end) = viewport(scalar @$shown, $m->{vars}{highlight}, $rows);
    for my $i ($start .. $end - 1) {
        my $arrow = $i == $m->{vars}{highlight} ? '>' : ' ';
        my $row = clip_plain(sprintf(' %s %s', $arrow, $shown->[$i]), $w);
        push @lines, $i == $m->{vars}{highlight}
            ? sprintf('%s%-*s%s', $SGR_SELECTED, $w, $row, $SGR_RESET)
            : $row;
    }
    return @lines;
}

# The re-dial preview: one line per attachment the selected variable
# governs, under the "  {V} attachments:" header. With $target defined
# (editing), each row shows "-> resolved" for the prospective value when
# it differs from the current session. A leading blank separates the
# block from whatever precedes it.
sub vars_preview_lines {
    my ($m, $sel, $vmap, $target, $w) = @_;
    my @hits = attachments_for_var($m->{sessions}, $sel->{name});
    my %vmap = %$vmap;
    $vmap{$sel->{name}} = $target if defined $target;
    my @lines = ('');
    if (@hits) {
        push @lines, "  {$sel->{name}} attachments:";
        for my $a (@hits) {
            my $after = resolve_template($a->{template}, \%vmap);
            my $row = sprintf('    %-24s %-16s pid %s',
                $a->{template}, $a->{session}, $a->{pid});
            $row .= "  -> $after" if defined $target && $after ne $a->{session};
            push @lines, clip_plain($row, $w);
        }
    } else {
        push @lines, '  (no attachments reference this variable)';
    }
    return @lines;
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
# Returns true when $m->{sessions} now reflects the daemon, false when
# the list call failed and the old contents were left in place. Callers
# that go on to *interpret* the list (the action handlers) must bail on
# false: on a failed refresh the list is stale, and at startup it is
# empty, so searching it yields "session 'x' is gone" -- which would
# then overwrite the "shpool list: ..." error parked here and report a
# dead daemon as a missing session. Callers that only refresh-and-render
# can ignore the result; the parked error is what they wanted anyway.
sub refresh_sessions {
    my ($m, @extra) = @_;
    my $new = eval { fetch_sessions(@extra) };
    if ($@) {
        my $err = $@;
        chomp $err;
        model_set_error($m, "shpool list: $err");
        return 0;
    }
    model_refresh($m, $new);
    cancel_modal_if_target_gone($m);
    # In the vars view the displayed list depends on the sessions just
    # refreshed (the unset rows are derived from their templates), so
    # re-merge against the new list, keeping the cursor on its variable
    # by name. This also self-corrects the post-`var set` re-dial: the
    # refresh that follows a set lands here and merges against fresh
    # sessions.
    remerge_vars($m) if $m->{mode} eq 'vars';
    return 1;
}

# Drop kill/confirm_force modals whose target session has disappeared
# from under them — any refresh (event-driven, focus-gained, the
# keystroke fallback) can race ahead of the user. `create` is safe:
# mode_data is the partial name being typed, not a session reference.
sub cancel_modal_if_target_gone {
    my $m = shift;
    return unless $m->{mode} eq 'kill' || $m->{mode} eq 'confirm_force';
    my $name = $m->{mode_data};
    return if grep { $_->{name} eq $name } @{$m->{sessions}};
    $m->{mode}      = 'normal';
    $m->{mode_data} = '';
    model_set_error($m, "session '$name' is gone");
}

# Spawn `shpool events` as a child whose stdout we read line-by-line.
# Uses the two-arg `open '-|'` fork so we can silence the child's
# stderr before exec. The child can fail for several reasons — binary
# doesn't have the subcommand (older shpool), daemon isn't running,
# daemon predates the events socket, etc. — and they all converge on
# EOF on the pipe, which event_loop handles uniformly. We don't probe
# capability up front: the subscribe attempt itself is the cheapest,
# most accurate signal, and the EOF path is the same fallback either
# way. Returns (pid, fh) or (undef, undef) on fork failure.
sub spawn_events {
    my $pid = open my $fh, '-|';
    return (undef, undef) unless defined $pid;
    if ($pid == 0) {
        open STDERR, '>', '/dev/null';
        no warnings 'exec';
        exec { 'shpool' } 'shpool', @SHPOOL_FLAGS, 'events';
        POSIX::_exit(127);
    }
    return ($pid, $fh);
}

# Idempotent: spawns an events subscriber if we don't already have
# one. Used at startup, after shell_attach returns, and after the
# EnsureDaemon path so the subscription comes back without the user
# having to do anything. Not called from the EOF branch of event_loop
# — see the comment there.
sub ensure_events {
    my $m = shift;
    return if defined $m->{events_pid};
    ($m->{events_pid}, $m->{events_fh}) = spawn_events();
    $EVENTS_PID = $m->{events_pid};
}

# Stop the events subscriber and reap it. SIGTERM the child even if
# it has already exited on its own (e.g. the daemon dropped us);
# waitpid then just reaps the zombie.
sub teardown_events {
    my $m = shift;
    return unless defined $m->{events_pid};
    kill 'TERM', $m->{events_pid};
    waitpid $m->{events_pid}, 0;
    close $m->{events_fh} if defined $m->{events_fh};
    $m->{events_pid} = undef;
    $m->{events_fh}  = undef;
    $EVENTS_PID      = undef;
}

# shpool command argv builders. Each inserts `--` before the
# user-controlled positionals so a session name or value that begins
# with a dash (e.g. "-sh") isn't parsed as a flag by shpool's argument
# parser. Session/variable names are \w+, but variable values are
# unconstrained, so var-set needs the guard too.
sub attach_cmd {
    my ($name, $force) = @_;
    my @cmd = ('shpool', @SHPOOL_FLAGS, 'attach');
    push @cmd, '-f' if $force;
    push @cmd, '--', $name;
    return @cmd;
}

sub kill_cmd {
    my ($name) = @_;
    return ('shpool', @SHPOOL_FLAGS, 'kill', '--', $name);
}

sub var_set_cmd {
    my ($name, $value) = @_;
    return ('shpool', @SHPOOL_FLAGS, 'var', 'set', '--', $name, $value);
}

# Spawn `shpool attach <name>`, handing the TTY over to the child.
# Used for both Attach and Create (a name shpool doesn't know is
# created on the fly). Clears the rendered frame first so the user's
# freshly-attached shell starts on a clean viewport. Returns true on
# successful exit.
#
# Tears the events subscriber down for the duration of the attached
# session: shperl is blocked in system(), so it can't drain the events
# pipe, and the daemon would eventually drop the connection anyway
# (bounded per-subscriber queue). Not strictly required — the
# subscriber would die on its own and ensure_events would respawn it —
# but this saves a process and makes the reconnect deterministic.
sub shell_attach {
    my ($m, $name, $force) = @_;
    # 2J + H: clear visible area and home the cursor so the user's
    # freshly-attached shell starts on a clean viewport. No \e[3J —
    # preserve scrollback.
    print STDOUT "\e[2J\e[H";
    my @cmd = attach_cmd($name, $force);
    teardown_events($m);
    my $rc = system @cmd;
    ensure_events($m);
    return $rc == 0;
}

# Run `shpool kill <name>`, returning (rc, err_message). shpool's
# stderr (e.g. "no session named 'foo'") is more informative than a
# generic failure, so we use it when present. Captures stderr rather
# than letting it land in the alt-screen.
sub shell_kill {
    my $name = shift;
    my ($rc, undef, $err) = run_capture(kill_cmd($name));
    my $detail = tidy_stderr($err);
    my $msg = length $detail ? "kill $name: $detail" : "kill $name failed";
    return ($rc, $msg);
}

# Post-action tail shared by attach/create/kill: refresh the session
# list, reselect the target by name if still present, and park an
# error message if the action failed.
sub finish_action {
    my ($m, $name, $ok, $err_msg) = @_;
    # The user just completed an action — any stale-select state
    # from before is no longer relevant. Cleared before the refresh
    # so refresh_sessions can re-raise it if something new went
    # away mid-action (the new alert wins over the irrelevant old).
    $m->{stale_select} = 0;
    $m->{error}        = undef;
    refresh_sessions($m);
    for my $i (0 .. $#{$m->{sessions}}) {
        if ($m->{sessions}[$i]{name} eq $name) {
            $m->{selected} = $i;
            last;
        }
    }
    model_set_error($m, $err_msg) if !$ok;
}

sub event_loop {
    my $m = shift;
    my $buf;
    my $stdin_fno = fileno(STDIN);
    # Initial fetch is unconditional: event_loop runs once per run_tui
    # iteration (every attach/create/etc tears down and re-enters us),
    # and the terminal may have resized during that external command
    # without us noticing. Clear before the read so a WINCH between
    # the two leaves the flag set for the next iteration — never miss
    # a resize.
    $WINCH_PENDING = 0;
    my ($w, $h) = tty_size();
    while (1) {
        if ($WINCH_PENDING) {
            $WINCH_PENDING = 0;
            ($w, $h) = tty_size();
        }
        my $frame = render($m, $w, $h);
        print STDOUT $frame;

        # 4-arg select over STDIN plus (if subscribed) the events fh.
        # Using built-in select + vec keeps this core-deps-only; an
        # IO::Select wrapper would add nothing.
        my $rin = '';
        vec($rin, $stdin_fno, 1) = 1;
        my $ev_fno;
        if (defined $m->{events_fh}) {
            $ev_fno = fileno($m->{events_fh});
            vec($rin, $ev_fno, 1) = 1;
        }
        # Wake on input, a push event, or — so the relative-age columns
        # advance while the table sits idle — when the soonest on-screen
        # age would next change. undef blocks forever (empty list); a bare
        # timeout wake finds nothing ready and loops back to re-render with
        # a fresh clock, firing neither the events drain nor the keystroke
        # fallback (both gated on their fd's bit).
        my $delay_ms = next_render_delay_ms($m, now_unix_ms());
        my $timeout  = defined $delay_ms ? $delay_ms / 1000 : undef;
        # select(2) writes the result mask into the input arg, so copy.
        my $rout = $rin;
        my $nfound = select($rout, undef, undef, $timeout);
        if ($nfound < 0) {
            next if $!{EINTR};      # SIGWINCH — re-render
            die "select: $!";
        }

        # Drain events first so the refreshed state is in place before
        # we react to the keystroke (matters for Enter: the attached
        # flag drives the force-confirm path). The wire payload is
        # content-free — every event just means "call list again" —
        # so we discard the bytes and let refresh_sessions do the work.
        if (defined $ev_fno && vec($rout, $ev_fno, 1)) {
            my $junk;
            my $got = sysread($m->{events_fh}, $junk, 4096);
            if (!defined $got) {
                die "read events: $!" unless $!{EINTR};
            } elsif ($got == 0) {
                # EOF — daemon went away, slow-subscriber drop, etc.
                # Reap; don't auto-respawn (ensure_events from
                # shell_attach/EnsureDaemon retries on its own —
                # auto-retry here risks a tight loop if the daemon
                # is genuinely down).
                teardown_events($m);
                refresh_sessions($m);
                # Don't clobber a more informative error from
                # refresh_sessions itself (e.g. "shpool list: ...").
                model_set_error($m, 'events subscription dropped — press D to retry')
                    unless defined $m->{error};
            } else {
                refresh_sessions($m);
            }
        }

        if (vec($rout, $stdin_fno, 1)) {
            my $n = sysread(STDIN, $buf, 16);
            if (!defined $n) {
                next if $!{EINTR};
                die "read stdin: $!";
            }
            return [ 'quit' ] if $n == 0;
            my $action = process_input($buf, $m);
            if ($action) {
                # Handled inline so the alt-screen stays up — no point
                # bouncing out to run_tui for a refresh-shaped action.
                if ($action->[0] eq 'ensure_daemon') {
                    refresh_sessions($m, '--daemonize');
                    ensure_events($m);
                    next;
                }
                # Set a template variable and stay in the vars view. The
                # affected sessions re-dial in the daemon; re-fetching
                # vars + sessions makes the preview reflect the new
                # resolution at once (events then keep it current).
                if ($action->[0] eq 'var_set') {
                    my (undef, $vn, $vv) = @$action;
                    my ($ok, undef, $err) = run_capture(var_set_cmd($vn, $vv));
                    vars_edit_clear($m);
                    if ($ok) {
                        # The set may have promoted an unset row to a set
                        # one (or added a brand-new var); pull the fresh
                        # set rows, point the cursor at the var we just
                        # set, then let refresh_sessions re-merge the
                        # unset rows against the re-dialed sessions and
                        # carry the cursor across the resort by name.
                        my $fresh = eval { fetch_vars() };
                        if ($fresh) {
                            $m->{vars}{list} = $fresh;
                            my ($i) = grep { $fresh->[$_]{name} eq $vn }
                                0 .. $#$fresh;
                            $m->{vars}{sel} = $i // 0;
                        }
                        refresh_sessions($m);
                    } else {
                        $err =~ s/^\s+|\s+$//g;
                        model_set_error($m,
                            length $err ? "var set $vn: $err" : "var set $vn failed");
                    }
                    next;
                }
                # Detect create-time variable prompts. A new session whose
                # name references vars not yet set drops into the per-var
                # prompt mode instead of attaching: staying in the
                # alt-screen here is mandatory for frame-parity — bouncing
                # out to the create action-handler would tear down and
                # re-enter the alt screen (flicker). With every referenced
                # var already set, fall through to the create→attach
                # action unchanged.
                if ($action->[0] eq 'create') {
                    my (undef, $name) = @$action;
                    my $vars = eval { fetch_vars() };
                    if ($@) {
                        (my $e = $@) =~ s/^\s+|\s+$//g;
                        model_set_error($m, "shpool var list: $e");
                        next;
                    }
                    my %set = map { $_->{name} => $_->{value} } @$vars;
                    my @unknown = unknown_template_vars($name, \%set);
                    if (@unknown) {
                        $m->{mode}       = 'create_vars';
                        $m->{var_prompt} = {
                            name      => $name,
                            vars      => \@unknown,
                            idx       => 0,
                            input     => '',
                            collected => [],
                            set_vars  => \%set,
                        };
                        next;
                    }
                    return [ 'create', $name ];
                }
                # Apply collected variable values, then attach. Set each
                # pair in order (last-write-wins against any concurrent
                # daemon-side change); on a failure park the error and
                # abort with no attach — the mode is already normal (the
                # prompt dropped to it on the final Enter) so the error
                # surfaces. Partial sets linger (no rollback): a later set
                # that fails leaves the earlier ones applied, and the next
                # create detect sees them as known.
                if ($action->[0] eq 'create_vars') {
                    my (undef, $name, $pairs) = @$action;
                    my $failed = 0;
                    for my $p (@$pairs) {
                        my ($vn, $vv) = @$p;
                        my ($ok, undef, $err) = run_capture(var_set_cmd($vn, $vv));
                        next if $ok;
                        my $detail = tidy_stderr($err);
                        model_set_error($m,
                            length $detail ? "var set $vn: $detail" : "var set $vn failed");
                        $failed = 1;
                        last;
                    }
                    next if $failed;
                    return [ 'create', $name ];
                }
                return $action;
            }
            # Fallback path when we're not subscribed: pick up state
            # changes from other clients on each keystroke. Skipped in
            # modal modes so typing doesn't storm shpool with list
            # calls. Unneeded when events are flowing (they already
            # poked us above), so it's gated on the subscription state.
            refresh_sessions($m)
                if !defined $m->{events_fh} && $m->{mode} eq 'normal';
        }
    }
}

# ---------------------------------------------------------------------------
# Action handlers
# ---------------------------------------------------------------------------
# Handlers run in run_tui after event_loop returns an action and the
# alt-screen is down. Each owns its own pre-flight, shell-out, and
# error-bar message. `quit` has no handler (run_tui returns directly);
# `ensure_daemon` is handled inline in event_loop without tearing down
# the alt-screen — see the comment there.

# Look up a session by name; on miss, set the standard
# "session 'X' is gone" error and return undef. Hoisted out because
# three handlers (attach, attach_force, kill) repeat the same lookup-
# and-bail.
sub session_or_error {
    my ($m, $name) = @_;
    my ($sess) = grep { $_->{name} eq $name } @{$m->{sessions}};
    return $sess if $sess;
    model_set_error($m, "session '$name' is gone");
    return undef;
}

# Package-scoped (not `my`) so tests.pl can dispatch actions through the
# real table, the same way run_tui does. The rest of the dispatch tables
# stay lexical -- they're reachable through named subs like
# process_normal; this one is only ever reached from run_tui.
our %ACTION_HANDLER = (
    attach => sub {
        my ($m, $name) = @_;
        # Pre-flight: refresh and verify the session still exists and
        # is not already attached elsewhere. shpool reports "already
        # has a terminal attached" on stderr with exit 0, and piping
        # stderr breaks shpool's own detach detection, so we check
        # the attached flag here instead. A race into Attached since
        # the keystroke promotes to confirm_force rather than
        # silently no-opping.
        refresh_sessions($m) or return;
        my $sess = session_or_error($m, $name) or return;
        if ($sess->{attached}) {
            $m->{mode}      = 'confirm_force';
            $m->{mode_data} = $name;
            return;
        }
        my $rc = shell_attach($m, $name);
        finish_action($m, $name, $rc, "shpool attach $name failed");
    },
    attach_force => sub {
        my ($m, $name) = @_;
        refresh_sessions($m) or return;
        session_or_error($m, $name) or return;
        my $rc = shell_attach($m, $name, 1);
        finish_action($m, $name, $rc, "shpool attach -f $name failed");
    },
    create => sub {
        my ($m, $name) = @_;
        # Pre-flight: reject names that already exist. `shpool attach`
        # is create-or-attach, so without this check a duplicate name
        # silently attaches (or flashes "already has a terminal
        # attached" on stderr and no-ops) — neither is what the
        # create prompt implies.
        refresh_sessions($m) or return;
        if (grep { $_->{name} eq $name } @{$m->{sessions}}) {
            model_set_error($m, "session '$name' already exists");
            return;
        }
        my $rc = shell_attach($m, $name);
        finish_action($m, $name, $rc, "shpool attach $name failed");
    },
    kill => sub {
        my ($m, $name) = @_;
        refresh_sessions($m) or return;
        session_or_error($m, $name) or return;
        # Move the cursor off the target before the kill so the
        # post-kill refresh doesn't raise stale_select on a session
        # we deliberately removed.
        model_advance_off($m, $name);
        my ($rc, $err_msg) = shell_kill($name);
        finish_action($m, $name, $rc, $err_msg);
    },
);

# $session, when given, is the `shperl SESSION` startup target. It is
# dispatched through the ordinary 'attach' action handler before the
# first render, which makes `shperl foo` exactly equivalent to starting
# shperl and pressing Enter on foo's row -- same pre-flight refresh,
# same confirm_force promotion when foo is attached elsewhere, same
# error parked in the table when it doesn't exist. Deliberately not a
# separate attach path: there is one definition of "attach to a
# session" and this inherits changes to it.
#
# It runs here rather than in main() because the handler communicates
# by mutating $m->{mode} (confirm_force) or $m->{error}, and only the
# loop below renders those. Cooked-mode tty is what the handler wants
# anyway -- the loop runs handlers with raw/alt torn down too.
sub run_tui {
    my ($m, $session) = @_;
    # Sets the recompute flag and interrupts select on resize.
    $SIG{WINCH} = sub { $WINCH_PENDING = 1 };

    $ACTION_HANDLER{attach}->($m, $session) if defined $session;

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
        return if $cmd eq 'quit';
        my $handler = $ACTION_HANDLER{$cmd}
            or die "internal: unknown action '$cmd'\n";
        $handler->($m, @args);
    }
}

# Parse top-level flags from @ARGV into @SHPOOL_FLAGS. Mirrors the
# four global flags shpool itself accepts; everything is forwarded
# verbatim to every shpool shell-out. Unknown flags or more than one
# positional arg are a usage error.
#
# Returns the optional SESSION positional (undef when absent), which
# main() hands to run_tui as a startup attach target.
sub parse_args {
    my ($config_file, $log_file, $socket);
    my $verbose = 0;
    GetOptions(
        'config-file=s' => \$config_file,
        'log-file=s'    => \$log_file,
        'socket=s'      => \$socket,
        'verbose|v+'    => \$verbose,
    ) or die "Usage: shperl [--config-file PATH] [--log-file PATH] [--socket PATH] [-v ...] [SESSION]\n";
    @ARGV <= 1
        or die "shperl: unexpected argument(s): @ARGV[1 .. $#ARGV]\n";
    my ($session) = @ARGV;
    !defined $session || length $session
        or die "shperl: empty session name\n";

    @SHPOOL_FLAGS = ();
    push @SHPOOL_FLAGS, '--config-file', $config_file if defined $config_file;
    push @SHPOOL_FLAGS, '--log-file',    $log_file    if defined $log_file;
    push @SHPOOL_FLAGS, ('-v') x $verbose;
    push @SHPOOL_FLAGS, '--socket',      $socket      if defined $socket;

    return $session;
}

sub main {
    my $session = parse_args();
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
    # Subscribe before the initial list so events firing during the
    # list call still wake us. Doesn't close the window fully — an
    # event between the fork and the child's connect is still lost,
    # but EVENTS.md (§Slow subscribers) is clear that there's no
    # replay, so this is the best we can do without per-action polls.
    #
    # The teardown_events call below is load-bearing for clean exit,
    # not just hygiene: open('-|') makes Perl track the child PID, and
    # the implicit close when $m goes out of scope does a blocking
    # waitpid on it. Without an explicit kill first, shperl hangs
    # holding the terminal after `q` until the events child happens to
    # die on its own — which is why the END-block kill alone isn't
    # enough (END fires after scope cleanup, too late).
    eval {
        ensure_events($m);
        refresh_sessions($m);
        run_tui($m, $session);
    };
    my $err = $@;
    teardown_events($m);
    die $err if $err;
}

# Run as a script unless loaded via `require`. The modulino pattern
# is here so tests.pl can poke at internal subs (process_normal,
# model_refresh, etc.) cheaply, without subprocess + pty mocking.
main() unless caller;

1;
