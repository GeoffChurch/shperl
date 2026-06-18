#!/usr/bin/env perl
# Unit tests for shperl. Loads shperl.pl via require (the modulino
# trick at the bottom of shperl.pl means main() doesn't auto-run when
# there's a caller), then exercises individual subs against built
# fixtures. Run with `perl tests.pl` or `prove tests.pl`.

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Test::More;

require "$FindBin::Bin/shperl.pl";

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Two-session model with "foo" selected. events_fh is set to a dummy
# defined value so handlers that pre-flight with `refresh_sessions
# unless defined $m->{events_fh}` skip the real shell-out (which
# would overwrite our fixture from a live shpool daemon).
sub make_model {
    my $m = main::model_new();
    main::model_refresh($m, [
        { name => 'foo', status => 'Disconnected',
          started_at_unix_ms           => 100,
          last_connected_at_unix_ms    => 100,
          last_disconnected_at_unix_ms => 100 },
        { name => 'bar', status => 'Disconnected',
          started_at_unix_ms           => 90,
          last_connected_at_unix_ms    => 90,
          last_disconnected_at_unix_ms => 90 },
    ]);
    $m->{selected}  = 0;          # foo
    $m->{events_fh} = \*STDIN;    # skip the pre-flight refresh
    return $m;
}

# ---------------------------------------------------------------------------
# process_normal: dispatch table, mode-change-stops-iteration, etc.
# ---------------------------------------------------------------------------

subtest 'mode-change stops iteration' => sub {
    my $m = make_model();
    my $action = main::process_normal(
        [ [byte=>ord('d')], [byte=>ord('q')] ], $m );
    is($action, undef, 'q after d is not processed');
    is($m->{mode},      'kill', 'mode switched to kill');
    is($m->{mode_data}, 'foo',  'mode_data is target name');
};

subtest 'non-mode-changing handlers continue iterating' => sub {
    my $m = make_model();
    main::process_normal(
        [ [byte=>ord('j')], [byte=>ord('j')] ], $m );
    is($m->{selected}, 0, 'selected wraps after two j (0 -> 1 -> 0)');
};

subtest 'action return propagates immediately' => sub {
    my $m = make_model();
    my $action = main::process_normal(
        [ [byte=>ord('q')], [byte=>ord('j')] ], $m );
    is_deeply($action, ['quit'], 'q returns [quit]');
    is($m->{selected}, 0, 'j after q is not processed');
};

subtest 'NewSession switches to create mode and stops' => sub {
    my $m = make_model();
    my $action = main::process_normal(
        [ [byte=>ord('n')], [byte=>ord('x')] ], $m );
    is($action, undef, 'returns undef');
    is($m->{mode},      'create', 'mode switched to create');
    is($m->{mode_data}, '',
        'x not appended (would only happen in create-mode handler)');
};

subtest 'unmapped token is silently ignored' => sub {
    my $m = make_model();
    main::process_normal(
        [ [byte=>ord('z')], [byte=>ord('j')] ], $m );
    is($m->{selected}, 1, 'z ignored, j processed normally');
};

subtest 'Enter force-promote stops iteration' => sub {
    my $m = make_model();
    $m->{sessions}[0]{attached} = 1;
    my $action = main::process_normal(
        [ [byte=>ord(' ')], [byte=>ord('q')] ], $m );
    is($action, undef, 'q not processed after force-promote');
    is($m->{mode},      'confirm_force', 'mode switched');
    is($m->{mode_data}, 'foo',           'target carried over');
};

subtest 'Enter on non-attached returns attach immediately' => sub {
    my $m = make_model();
    my $action = main::process_normal(
        [ [byte=>ord(' ')], [byte=>ord('q')] ], $m );
    is_deeply($action, ['attach', 'foo'], 'attach action returned');
};

# ---------------------------------------------------------------------------
# stale_select: ack-on-first-keystroke + navigation clears the flag
# ---------------------------------------------------------------------------

subtest 'stale_select consumes Enter as acknowledgment' => sub {
    my $m = make_model();
    $m->{stale_select} = 1;
    $m->{error}        = "session 'foo' is gone";
    my $action = main::process_normal( [ [byte=>ord(' ')] ], $m );
    is($action,             undef, 'Enter does not produce an action');
    is($m->{stale_select},  0,     'flag cleared');
    is($m->{error},         undef, 'error cleared');
};

subtest 'stale_select consumes KillSession as acknowledgment' => sub {
    my $m = make_model();
    $m->{stale_select} = 1;
    my $action = main::process_normal( [ [byte=>ord('d')] ], $m );
    is($action,            undef,  'd does not produce an action');
    is($m->{mode},         'normal', 'mode unchanged (d not dispatched)');
    is($m->{stale_select}, 0,      'flag cleared');
};

subtest 'stale_select clears on navigation' => sub {
    my $m = make_model();
    $m->{stale_select} = 1;
    main::process_normal( [ [byte=>ord('j')] ], $m );
    is($m->{stale_select}, 0, 'flag cleared by j');
    is($m->{selected},     1, 'j moved selection');
};

# ---------------------------------------------------------------------------
# model_refresh: stale_select on missing prev_name, list growth doesn't
# revalidate, hit clears the flag
# ---------------------------------------------------------------------------

subtest 'model_refresh sets stale_select when selection vanishes' => sub {
    my $m = make_model();   # foo selected
    main::model_refresh($m, [
        { name => 'bar', status => 'Disconnected',
          started_at_unix_ms           => 90,
          last_connected_at_unix_ms    => 90,
          last_disconnected_at_unix_ms => 90 },
    ]);
    is($m->{stale_select}, 1, 'flag set');
    is(main::model_selected_name($m), undef,
        'no name reported even though $selected is in bounds');
    like($m->{error}, qr/foo/, 'error mentions the lost session');
};

subtest 'list growth does not silently revalidate a stale selection' => sub {
    my $m = make_model();
    # foo killed
    main::model_refresh($m, [
        { name => 'bar', status => 'Disconnected',
          started_at_unix_ms => 90, last_connected_at_unix_ms => 90,
          last_disconnected_at_unix_ms => 90 },
    ]);
    is($m->{stale_select}, 1, 'stale after kill');
    # someone else creates "qux"
    main::model_refresh($m, [
        { name => 'qux', status => 'Disconnected',
          started_at_unix_ms => 200, last_connected_at_unix_ms => 200,
          last_disconnected_at_unix_ms => 200 },
        { name => 'bar', status => 'Disconnected',
          started_at_unix_ms => 90, last_connected_at_unix_ms => 90,
          last_disconnected_at_unix_ms => 90 },
    ]);
    is($m->{stale_select}, 1, 'still stale after list growth');
    is(main::model_selected_name($m), undef,
        'no name reported even though the index now has an occupant');
};

subtest 'model_refresh clears stale_select when prev_name reappears via navigation+reselect' => sub {
    my $m = make_model();
    main::model_refresh($m, [
        { name => 'bar', status => 'Disconnected',
          started_at_unix_ms => 90, last_connected_at_unix_ms => 90,
          last_disconnected_at_unix_ms => 90 },
    ]);
    is($m->{stale_select}, 1, 'stale after foo killed');
    main::model_select_next($m);   # clears stale, picks bar
    is($m->{stale_select}, 0, 'flag cleared by navigation');
    main::model_refresh($m, [
        { name => 'bar', status => 'Disconnected',
          started_at_unix_ms => 90, last_connected_at_unix_ms => 90,
          last_disconnected_at_unix_ms => 90 },
    ]);
    is($m->{stale_select}, 0, 'flag stays cleared on subsequent refresh hit');
};

# Strip ANSI CSI sequences so substring matches work against the
# rendered text. label_push_* chunks reset between segments, so e.g.
# `kill "foo"` lands in the output as `kill <reset>"foo"` and a
# naive regex would miss it.
sub strip_ansi { my $s = shift; $s =~ s/\e\[[\d;?]*[a-zA-Z]//g; return $s }

# ---------------------------------------------------------------------------
# bottom_bar_label: priority is modal > error > bindings
# ---------------------------------------------------------------------------

# Label is [styled_bytes, visible_chars]; strip ANSI from the bytes
# for substring matching.
sub label_text { strip_ansi($_[0][0]) }

subtest 'bottom_bar_label picks modal prompt over an error' => sub {
    for my $case (
        [ create        => 'foo' => qr/new session: foo/ ],
        [ kill          => 'foo' => qr/kill "foo"/        ],
        [ confirm_force => 'foo' => qr/"foo" already attached/ ],
    ) {
        my ($mode, $data, $expect) = @$case;
        my $m = make_model();
        $m->{mode}      = $mode;
        $m->{mode_data} = $data;
        $m->{error}     = "background error msg";
        my $text = label_text( main::bottom_bar_label($m) );
        like($text,   $expect,                  "$mode prompt selected");
        unlike($text, qr/background error msg/, "$mode hides the error");
    }
};

subtest 'bottom_bar_label falls back to error in normal mode' => sub {
    my $m = make_model();
    $m->{error} = "something went wrong";
    my $text = label_text( main::bottom_bar_label($m) );
    like($text, qr/something went wrong/, 'error shown');
};

subtest 'bottom_bar_label falls back to bindings when no error' => sub {
    my $m = make_model();
    my $text = label_text( main::bottom_bar_label($m) );
    like($text, qr/quit/, 'normal bindings shown');
};

# ---------------------------------------------------------------------------
# render: modal prompts outrank errors so a background refresh that
# raises an error mid-input doesn't clobber the user's typing
# ---------------------------------------------------------------------------

subtest 'create modal prompt is shown even when an error is set' => sub {
    my $m = make_model();
    $m->{mode}      = 'create';
    $m->{mode_data} = 'my_typed_input';
    $m->{error}     = "session 'foo' is gone";
    my $out = strip_ansi( main::render($m, 80, 24) );
    like($out,   qr/my_typed_input/, 'typed input visible');
    unlike($out, qr/foo' is gone/,   'error not shown over the prompt');
};

subtest 'confirm modals also outrank errors' => sub {
    for my $case (
        [ kill          => qr/kill "foo"/ ],
        [ confirm_force => qr/"foo" already attached/ ],
    ) {
        my ($mode, $expect) = @$case;
        my $m = make_model();
        $m->{mode}      = $mode;
        $m->{mode_data} = 'foo';
        $m->{error}     = "background error msg";
        my $out = strip_ansi( main::render($m, 80, 24) );
        like($out,   $expect,                  "$mode prompt visible");
        unlike($out, qr/background error msg/, "$mode hides the error");
    }
};

subtest 'normal mode still shows errors' => sub {
    my $m = make_model();
    $m->{error} = "session 'foo' is gone";
    my $out = strip_ansi( main::render($m, 80, 24) );
    like($out, qr/foo' is gone/, 'error visible in normal mode');
};

# ---------------------------------------------------------------------------
# model_advance_off + post-kill refresh: a deliberate kill shouldn't
# raise stale_select on the session the user just asked us to remove
# ---------------------------------------------------------------------------

sub session_record {
    my ($name, $ts) = @_;
    return {
        name => $name, status => 'Disconnected',
        started_at_unix_ms           => $ts,
        last_connected_at_unix_ms    => $ts,
        last_disconnected_at_unix_ms => $ts,
    };
}

subtest 'model_advance_off mid-list: cursor lands on next neighbor' => sub {
    my $m = main::model_new();
    main::model_refresh($m, [
        session_record('a', 300),
        session_record('b', 200),
        session_record('c', 100),
    ]);
    $m->{selected} = 1;   # 'b' (between a and c by sort)
    main::model_advance_off($m, 'b');
    is(main::model_selected_name($m), 'c', 'cursor advanced to next');
    # Now simulate the kill: refresh with b gone.
    main::model_refresh($m, [
        session_record('a', 300),
        session_record('c', 100),
    ]);
    is($m->{stale_select}, 0,   'no stale_select after deliberate kill');
    is($m->{error},        undef, 'no error after deliberate kill');
    is(main::model_selected_name($m), 'c', 'cursor still on c');
};

subtest 'model_advance_off at end: cursor lands on previous' => sub {
    my $m = main::model_new();
    main::model_refresh($m, [
        session_record('a', 300),
        session_record('b', 200),
    ]);
    $m->{selected} = 1;   # 'b' is last
    main::model_advance_off($m, 'b');
    is(main::model_selected_name($m), 'a', 'cursor advanced to previous');
    main::model_refresh($m, [ session_record('a', 300) ]);
    is($m->{stale_select}, 0, 'no stale_select');
    is(main::model_selected_name($m), 'a', 'cursor still on a');
};

subtest 'model_advance_off when target is the only session: cursor clears' => sub {
    my $m = main::model_new();
    main::model_refresh($m, [ session_record('a', 300) ]);
    $m->{selected} = 0;
    main::model_advance_off($m, 'a');
    is(main::model_selected_name($m), undef, 'no selection');
    is($m->{stale_select}, 0, 'cleared via out-of-bounds, not stale_select');
    main::model_refresh($m, []);
    is($m->{stale_select}, 0, 'still no stale_select after empty refresh');
    is($m->{error},        undef, 'no error from a deliberate-empty');
};

subtest 'model_advance_off is a no-op when target is not selected' => sub {
    my $m = main::model_new();
    main::model_refresh($m, [
        session_record('a', 300),
        session_record('b', 200),
    ]);
    $m->{selected} = 0;   # on 'a'
    main::model_advance_off($m, 'b');   # killing the unselected one
    is(main::model_selected_name($m), 'a', 'cursor unchanged');
};

# ---------------------------------------------------------------------------
# finish_action: stale state from before the action shouldn't survive
# its completion. The user has moved on.
# ---------------------------------------------------------------------------

# Wrap finish_action calls in a mock so refresh_sessions doesn't
# shell out to a real shpool. The closure populates whatever the
# caller wants the post-refresh sessions to look like.
sub with_mocked_refresh (&;$) {
    my ($body, $sessions) = @_;
    no warnings 'redefine';
    local *main::refresh_sessions = sub {
        my $m = shift;
        $m->{sessions} = $sessions if defined $sessions;
    };
    $body->();
}

subtest 'finish_action clears prior stale_select when target exists' => sub {
    my $m = main::model_new();
    $m->{sessions}     = [ session_record('bar', 200) ];
    $m->{selected}     = 0;
    $m->{stale_select} = 1;
    $m->{error}        = "session 'foo' is gone";
    with_mocked_refresh(sub {
        main::finish_action($m, 'newbar', 1, undef);
    }, [
        session_record('newbar', 400),
        session_record('bar',    200),
    ]);
    is($m->{stale_select}, 0,        'stale_select cleared');
    is($m->{error},        undef,    'old error cleared');
    is(main::model_selected_name($m), 'newbar', 'cursor on new session');
};

subtest 'finish_action with failure sets new error, still clears stale' => sub {
    my $m = main::model_new();
    $m->{sessions}     = [ session_record('bar', 200) ];
    $m->{selected}     = 0;
    $m->{stale_select} = 1;
    $m->{error}        = "session 'foo' is gone";
    with_mocked_refresh(sub {
        main::finish_action($m, 'newbar', 0, 'shpool attach newbar failed');
    }, [ session_record('bar', 200) ]);   # newbar not created
    is($m->{stale_select}, 0, 'stale_select cleared');
    is($m->{error}, 'shpool attach newbar failed',
        'fresh action-failure error replaces the old stale one');
};

subtest 'finish_action lets the refresh re-raise stale_select for new losses' => sub {
    my $m = main::model_new();
    $m->{sessions}     = [ session_record('foo', 300), session_record('bar', 200) ];
    $m->{selected}     = 0;   # on foo
    $m->{stale_select} = 0;   # no prior stale state
    {
        no warnings 'redefine';
        local *main::refresh_sessions = sub {
            my $m = shift;
            # Simulate: foo vanished mid-action while we were doing
            # something else (kill bar, in this case).
            main::model_refresh($m, [ session_record('baz', 400) ]);
        };
        main::finish_action($m, 'bar', 1, undef);
    }
    is($m->{stale_select}, 1, 'fresh stale fired (foo went away mid-action)');
    like($m->{error}, qr/foo/, 'fresh error mentions the lost session');
};

# ---------------------------------------------------------------------------
# next_render_delay_ms: idle wake cadence mirrors format_age's buckets
# ---------------------------------------------------------------------------

subtest 'next_render_delay_ms ticks per-second in the sub-minute band' => sub {
    # 5.3s old: format_age shows "5s", flips to "6s" in 700ms.
    my $m = { sessions => [ session_record('a', 4_700) ] };
    is(main::next_render_delay_ms($m, 10_000), 700,
        'next whole second, not a full 1000ms');
};

subtest 'next_render_delay_ms floors at 100ms near a boundary' => sub {
    # 5.95s old: only 50ms to the next second — floored up to 100.
    my $m = { sessions => [ session_record('a', 4_050) ] };
    is(main::next_render_delay_ms($m, 10_000), 100, 'sub-100ms gap floored');
};

subtest 'next_render_delay_ms ticks per-minute in the Nm band' => sub {
    # 100s old: "1m", flips to "2m" at 120s — 20s away.
    my $m = { sessions => [ session_record('a', 100_000) ] };
    is(main::next_render_delay_ms($m, 200_000), 20_000, 'next whole minute');
};

subtest 'next_render_delay_ms takes the soonest change across sessions' => sub {
    # a is 1s old ("now", 4s until "5s"); b is 5.3s old (700ms until "6s").
    # The faster ticker sets the cadence.
    my $m = { sessions => [
        session_record('a', 9_000),
        session_record('b', 4_700),
    ] };
    is(main::next_render_delay_ms($m, 10_000), 700, 'min across all sessions');
};

subtest 'next_render_delay_ms is undef for an empty list' => sub {
    is(main::next_render_delay_ms({ sessions => [] }, 10_000), undef,
        'nothing to tick — block forever');
};

# ---------------------------------------------------------------------------
# Template variables: parsing + the attachment preview (PR #379)
# ---------------------------------------------------------------------------

subtest 'template_vars extracts {name} tokens, deduped, in order' => sub {
    is_deeply([ main::template_vars('{workspace}-edit') ], ['workspace'], 'single var');
    is_deeply([ main::template_vars('{a}-{b}-{a}') ], ['a','b'], 'dedup, first-seen order');
    is_deeply([ main::template_vars('plainsess') ], [], 'no vars');
};

subtest 'resolve_template substitutes known vars, leaves unknown literal' => sub {
    my $vars = { workspace => 'newproj', editor => 'vim' };
    is(main::resolve_template('{workspace}-edit', $vars), 'newproj-edit', 'known var');
    is(main::resolve_template('{workspace}-{editor}', $vars), 'newproj-vim', 'two vars');
    is(main::resolve_template('{gone}-x', $vars), '{gone}-x', 'unknown left as-is');
};

sub vars_sessions {
    return [
        { name => 'myproj-edit', attachments => [
            { session_name_template => '{workspace}-edit', pid => 111 } ] },
        { name => 'myproj-term', attachments => [
            { session_name_template => '{workspace}-term', pid => 222 } ] },
        { name => 'vim-notes', attachments => [
            { session_name_template => '{editor}-notes', pid => 333 } ] },
        { name => 'plainsess', attachments => [
            { session_name_template => 'plainsess', pid => 444 } ] },
    ];
}

subtest 'attachments_for_var finds only attachments referencing the var' => sub {
    my @hits = main::attachments_for_var(vars_sessions(), 'workspace');
    is(scalar @hits, 2, 'two attachments use {workspace}');
    is_deeply([ sort map { $_->{session} } @hits ],
        ['myproj-edit','myproj-term'], 'the right sessions');
    is_deeply([ sort { $a <=> $b } map { $_->{pid} } @hits ], [111,222], 'with their pids');
    is(scalar main::attachments_for_var(vars_sessions(), 'editor'), 1, 'editor governs one');
    is(scalar main::attachments_for_var(vars_sessions(), 'nope'), 0, 'unknown governs none');
};

sub make_vars_model {
    my $m = main::model_new();
    $m->{mode}     = 'vars';
    $m->{vars}{list}    = [ { name => 'editor', value => 'vim' },
                       { name => 'workspace', value => 'myproj' } ];
    $m->{vars}{sel}     = 0;
    $m->{sessions} = vars_sessions();
    return $m;
}

subtest 'vars browse: j/k move the cursor and wrap' => sub {
    my $m = make_vars_model();
    main::process_vars_input([ [byte=>ord 'j'] ], $m);
    is($m->{vars}{sel}, 1, 'j moves down');
    main::process_vars_input([ [byte=>ord 'j'] ], $m);
    is($m->{vars}{sel}, 0, 'j wraps to top');
    main::process_vars_input([ [byte=>ord 'k'] ], $m);
    is($m->{vars}{sel}, 1, 'k wraps to bottom');
};

subtest 'vars edit: e opens the value line prefilled; chars + Enter commit' => sub {
    my $m = make_vars_model();        # vars.sel 0 = editor=vim
    main::process_vars_input([ [byte=>ord 'e'] ], $m);
    is($m->{vars}{edit}, 1, 'edit started');
    is($m->{vars}{input}, 'vim', 'prefilled with the current value');
    main::process_vars_input([ map { [byte=>0x7f] } 1..3 ], $m);
    is($m->{vars}{input}, '', 'backspaced to empty');
    main::process_vars_input([ map { [byte=>ord $_] } split //, 'nano' ], $m);
    is($m->{vars}{input}, 'nano', 'typed new value');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'editor', 'nano' ], 'Enter commits a var_set action');
};

subtest 'vars edit: Esc cancels the edit but stays in the view' => sub {
    my $m = make_vars_model();
    main::process_vars_input([ [byte=>ord 'e'] ], $m);
    main::process_vars_input([ [byte=>ord 'x'] ], $m);
    is($m->{vars}{input}, 'vimx', 'typed into the edit line');
    main::process_vars_input([ ['bare_esc'] ], $m);
    is($m->{vars}{edit}, 0, 'edit cancelled');
    is($m->{mode}, 'vars', 'still in the vars view');
};

subtest 'vars browse: Esc and q both leave the view' => sub {
    my $m = make_vars_model();
    main::process_vars_input([ ['bare_esc'] ], $m);
    is($m->{mode}, 'normal', 'Esc returns to the session list');
    my $m2 = make_vars_model();
    main::process_vars_input([ [byte=>ord 'q'] ], $m2);
    is($m2->{mode}, 'normal', 'q returns to the session list');
};

# ---------------------------------------------------------------------------
# Golden full-frame render tests
# ---------------------------------------------------------------------------
# Normalize a frame for comparison: strip ANSI/cursor sequences and CRs,
# rstrip each line, drop trailing blank lines. Leading spaces and interior
# blanks are significant and preserved; trailing-space trimming keeps the
# goldens robust to editor/diff whitespace munging.
sub norm_frame {
    my $s = shift // '';
    $s =~ s/\e\[[\d;?]*[a-zA-Z]//g;
    $s =~ s/\r//g;
    my @l = split /\n/, $s, -1;
    s/[ \t]+$// for @l;
    pop @l while @l && $l[-1] eq '';
    return join "\n", @l;
}
sub frame_is { is(norm_frame($_[0]), norm_frame($_[1]), $_[2]) }

subtest 'golden: session list (clock mocked)' => sub {
    no warnings qw(redefine once);
    local *main::now_unix_ms = sub { 1_000_000_000 };
    my $m = main::model_new();
    main::model_refresh($m, [
        { name => 'web', status => 'Attached', attached => 1,
          started_at_unix_ms => 992_800_000,
          last_connected_at_unix_ms => 999_995_000,
          last_disconnected_at_unix_ms => 0 },
        { name => 'db', status => 'Disconnected', attached => 0,
          started_at_unix_ms => 996_400_000,
          last_connected_at_unix_ms => 996_400_000,
          last_disconnected_at_unix_ms => 999_400_000 },
    ]);
    $m->{selected} = 0;
    frame_is(main::render($m, 76, 8), <<'GOLDEN', 'session list frame');
                            shpool (2 sessions)
  name  created  active
*>web   2h       5s
  db    1h       10m
  j down   k up   spc attach   n new   d kill   D daemon   v vars   q quit
GOLDEN
};

subtest 'golden: empty session list' => sub {
    my $m = main::model_new();
    frame_is(main::render($m, 76, 8), <<'GOLDEN', 'empty list frame');
                            shpool (0 sessions)
  name  created  active
  (no sessions)
  j down   k up   spc attach   n new   d kill   D daemon   v vars   q quit
GOLDEN
};

subtest 'golden: vars view (browsing)' => sub {
    my $m = main::model_new();
    $m->{mode}  = 'vars';
    $m->{vars}{list} = [ { name => 'editor', value => 'vim' },
                    { name => 'workspace', value => 'myproj' } ];
    $m->{vars}{sel}  = 1;
    $m->{sessions} = [
        { name => 'myproj-edit', attachments => [ { session_name_template => '{workspace}-edit', pid => 111 } ] },
        { name => 'myproj-term', attachments => [ { session_name_template => '{workspace}-term', pid => 222 } ] },
        { name => 'vim-notes',   attachments => [ { session_name_template => '{editor}-notes',   pid => 333 } ] },
    ];
    frame_is(main::render($m, 72, 12), <<'GOLDEN', 'vars browsing frame');
                             variables (2)
   editor    = vim   (1 session)
 > workspace = myproj   (2 sessions)

  {workspace} attachments:
    {workspace}-edit         myproj-edit      pid 111
    {workspace}-term         myproj-term      pid 222
  j/k: select, e: set value, esc: back
GOLDEN
};

done_testing();
