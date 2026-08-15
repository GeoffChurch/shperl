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

subtest 'vars edit: e opens the value selector with an empty field; type + Enter commit' => sub {
    my $m = make_vars_model();        # vars.sel 0 = editor=vim
    main::process_vars_input([ [byte=>ord 'e'] ], $m);
    is($m->{vars}{edit}, 1, 'edit started');
    is($m->{vars}{field},  '', 'field starts empty (no prefill of the current value)');
    is($m->{vars}{filter}, '', 'filter starts empty');
    is($m->{vars}{highlight}, 0, 'highlight starts at the top');
    is_deeply($m->{vars}{cands}, ['vim'],
        'candidates harvested ({editor}-notes -> vim)');
    main::process_vars_input([ map { [byte=>ord $_] } split //, 'nano' ], $m);
    is($m->{vars}{field}, 'nano', 'typed new value into the field');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'editor', 'nano' ], 'Enter commits a var_set action');
};

subtest 'vars edit: Esc cancels the edit but stays in the view' => sub {
    my $m = make_vars_model();
    main::process_vars_input([ [byte=>ord 'e'] ], $m);
    main::process_vars_input([ [byte=>ord 'x'] ], $m);
    is($m->{vars}{field}, 'x', 'typed into the field');
    main::process_vars_input([ ['bare_esc'] ], $m);
    is($m->{vars}{edit}, 0, 'edit cancelled');
    is($m->{vars}{field}, '', 'field reset on cancel');
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
# candidate_values: harvest candidate values from existing session names
# ---------------------------------------------------------------------------

subtest 'candidate_values: single template strips prefix/suffix' => sub {
    my $sessions = [
        { name => 'myproj-edit', attachments => [
            { session_name_template => '{workspace}-edit', pid => 1 } ] },
        { name => 'demo-edit',   attachments => [] },        # detached: still a target
        { name => 'noise',       attachments => [] },        # doesn't fit prefix/suffix
    ];
    is_deeply(
        [ main::candidate_values($sessions, { workspace => 'myproj' }, 'workspace') ],
        [ 'myproj', 'demo' ],
        'current value first, then the captured value from a detached session');
};

subtest 'candidate_values: union across a variable\'s templates' => sub {
    my $sessions = [
        { name => 'a-edit', attachments => [
            { session_name_template => '{w}-edit', pid => 1 } ] },
        { name => 'b-term', attachments => [
            { session_name_template => '{w}-term', pid => 2 } ] },
        { name => 'c-edit', attachments => [] },
    ];
    is_deeply(
        [ main::candidate_values($sessions, { w => 'a' }, 'w') ],
        [ 'a', 'c', 'b' ],
        'captures unioned across {w}-edit (a,c) then {w}-term (b), current first');
};

subtest 'candidate_values: co-vars pinned to current values' => sub {
    my $sessions = [
        { name => 'vim-myproj-edit', attachments => [
            { session_name_template => '{editor}-{workspace}-edit', pid => 1 } ] },
        { name => 'vim-demo-edit',   attachments => [] },
        { name => 'nano-other-edit', attachments => [] },   # editor!=vim -> excluded
    ];
    is_deeply(
        [ main::candidate_values($sessions,
            { editor => 'vim', workspace => 'myproj' }, 'workspace') ],
        [ 'myproj', 'demo' ],
        'editor pinned to vim, so only vim-*-edit names contribute');
};

subtest 'candidate_values: a delimiter-bearing co-var value pins literally' => sub {
    # editor="a-b" makes the pinned prefix "a-b-"; only names with that
    # exact prefix contribute, and the strip is on the literal string.
    my $sessions = [
        { name => 'a-b-myproj', attachments => [
            { session_name_template => '{editor}-{workspace}', pid => 1 } ] },
        { name => 'a-b-demo',   attachments => [] },
        { name => 'a-other',    attachments => [] },        # prefix "a-b-" mismatch
    ];
    is_deeply(
        [ main::candidate_values($sessions,
            { editor => 'a-b', workspace => 'myproj' }, 'workspace') ],
        [ 'myproj', 'demo' ],
        'capture is the remainder after the literal "a-b-" prefix');
};

subtest 'candidate_values: bare {V} template captures every session name' => sub {
    my $sessions = [
        { name => 'alpha', attachments => [
            { session_name_template => '{x}', pid => 1 } ] },
        { name => 'beta',  attachments => [] },
        { name => 'gamma', attachments => [] },
    ];
    is_deeply(
        [ main::candidate_values($sessions, { x => 'alpha' }, 'x') ],
        [ 'alpha', 'beta', 'gamma' ],
        'bare {x}: prefix and suffix both empty -> all names');
};

subtest 'candidate_values: no attached template for V yields current value only' => sub {
    my $sessions = [
        { name => 'myproj-edit', attachments => [
            { session_name_template => '{workspace}-edit', pid => 1 } ] },
    ];
    is_deeply(
        [ main::candidate_values($sessions, { gone => 'cur' }, 'gone') ],
        [ 'cur' ],
        'no template references {gone} -> just the current value');
};

subtest 'candidate_values: multibyte session name is char-safe (no panic)' => sub {
    use utf8;
    my $sessions = [
        { name => "caf\x{e9}-edit",  attachments => [
            { session_name_template => '{w}-edit', pid => 1 } ] },
        { name => "na\x{ef}ve-edit", attachments => [] },
    ];
    my @c = main::candidate_values($sessions, { w => "caf\x{e9}" }, 'w');
    is_deeply(\@c, [ "caf\x{e9}", "na\x{ef}ve" ],
        'strip works on characters, not bytes');
    is(length $c[1], 5, 'captured value is 5 characters (na\x{ef}ve)');
};

subtest 'candidate_values: empty capture is dropped' => sub {
    # Session named exactly "-edit" would capture "" under {w}-edit.
    my $sessions = [
        { name => '-edit',     attachments => [
            { session_name_template => '{w}-edit', pid => 1 } ] },
        { name => 'real-edit', attachments => [] },
    ];
    is_deeply(
        [ main::candidate_values($sessions, { w => 'cur' }, 'w') ],
        [ 'cur', 'real' ],
        'the empty capture from "-edit" is dropped; "real" kept');
};

subtest 'candidate_values: a template with {V} twice is skipped' => sub {
    my $sessions = [
        { name => 'a-a', attachments => [
            { session_name_template => '{v}-{v}', pid => 1 } ] },
        { name => 'x-y', attachments => [
            { session_name_template => '{v}-y',   pid => 2 } ] },
    ];
    is_deeply(
        [ main::candidate_values($sessions, { v => 'a' }, 'v') ],
        [ 'a', 'x' ],
        '{v}-{v} skipped; {v}-y still captures x');
};

subtest 'parse_var_list decodes UTF-8 var-list output to characters' => sub {
    # The var-list pipe yields raw UTF-8 bytes ("é" is the two bytes
    # \xC3\xA9). parse_var_list must decode so values are character
    # strings, like the JSON-decoded session names they compare against.
    my $vars = main::parse_var_list("editor\tcaf\xC3\xA9\nworkspace\tmyproj\n");
    is(scalar @$vars, 2, 'two variables parsed, sorted by name');
    is($vars->[0]{name}, 'editor', 'first name');
    is(length $vars->[0]{value}, 4, 'value is 4 characters, not 5 bytes');
    is($vars->[0]{value}, "caf\x{E9}", 'value decoded to café');
};

subtest 'candidate_values: a multibyte co-var value (decoded) strips correctly' => sub {
    use utf8;
    # The byte/char hazard end to end: the co-var "editor" arrives from
    # var list as UTF-8 bytes and is decoded by parse_var_list; the names
    # are characters (as from decode_json). The "café-" prefix must strip
    # off both names by character, not byte.
    my %map = map { $_->{name} => $_->{value} }
        @{ main::parse_var_list("editor\tcaf\xC3\xA9\nworkspace\tmyproj\n") };
    my $sessions = [
        { name => "caf\x{e9}-myproj", attachments => [
            { session_name_template => '{editor}-{workspace}', pid => 1 } ] },
        { name => "caf\x{e9}-demo", attachments => [] },
    ];
    is_deeply(
        [ main::candidate_values($sessions, \%map, 'workspace') ],
        [ 'myproj', 'demo' ],
        'café- strips from both names; myproj (current) first, then demo');
};

# ---------------------------------------------------------------------------
# filter_rank: subsequence filter + total-order ranking
# ---------------------------------------------------------------------------

subtest 'filter_rank: ASCII case-insensitive subsequence match' => sub {
    is_deeply([ main::filter_rank([ 'XRP', 'abc' ], 'xrp') ], [ 'XRP' ],
        'folded query matches a folded candidate; non-match dropped');
};

subtest 'filter_rank: exact match sorts to the top' => sub {
    is_deeply([ main::filter_rank([ 'xrpz', 'xrp', 'xrpa' ], 'xrp') ],
        [ 'xrp', 'xrpz', 'xrpa' ],
        'the exact candidate outranks the longer subsequence matches');
};

subtest 'filter_rank: contiguous before scattered (xr -> xrp before xmr)' => sub {
    is_deeply([ main::filter_rank([ 'xmr', 'xrp', 'djt' ], 'xr') ],
        [ 'xrp', 'xmr' ],
        'xrp (contains "xr") outranks xmr (scattered); djt drops out');
};

subtest 'filter_rank: sparse subsequence still matches (kb -> key-bugfix)' => sub {
    is_deeply([ main::filter_rank([ 'key-bugfix', 'unrelated' ], 'kb') ],
        [ 'key-bugfix' ],
        'k...b is a subsequence of key-bugfix; unrelated drops out');
};

subtest 'filter_rank: empty query keeps everything in harvest order' => sub {
    is_deeply([ main::filter_rank([ 'c', 'a', 'b' ], '') ], [ 'c', 'a', 'b' ],
        'no ranking applied');
};

subtest 'filter_rank: harvest index is the final tiebreak' => sub {
    # Both contiguous, first-match index 0, same char count -> harvest order.
    is_deeply([ main::filter_rank([ 'abx', 'aby' ], 'ab') ], [ 'abx', 'aby' ],
        'all keys equal but harvest index -> input order preserved');
};

subtest 'filter_rank: candidate length compared by characters, not bytes' => sub {
    # Both contain folded "x"; "X\x{e9}" is 2 chars, "aXc" is 3 chars.
    use utf8;
    is_deeply([ main::filter_rank([ 'aXc', "X\x{e9}" ], 'x') ],
        [ "X\x{e9}", 'aXc' ],
        'the 2-character multibyte candidate sorts before the 3-character one');
};

# ---------------------------------------------------------------------------
# Value-selector state machine (process_vars_input edit branch)
# ---------------------------------------------------------------------------

# A vars model carrying a known candidate set, mid-edit on the one
# variable. Sessions are shaped so {v}-edit harvests the given values
# (current value first via candidate_values).
sub vars_edit_model {
    my @cand_names = @_;                     # captured values to harvest
    my $m = main::model_new();
    $m->{mode} = 'vars';
    $m->{vars}{list} = [ { name => 'v', value => 'djt' } ];
    $m->{vars}{sel}  = 0;
    $m->{sessions}   = [
        { name => 'djt-edit', attachments => [
            { session_name_template => '{v}-edit', pid => 1 } ] },
        map { { name => "$_-edit", attachments => [] } } @cand_names,
    ];
    main::vars_edit_start($m);
    return $m;
}

subtest 'value selector: arrows fill the field and do not re-filter' => sub {
    my $m = vars_edit_model('xmr', 'xrp');   # cands: djt, xmr, xrp
    is_deeply($m->{vars}{cands}, [ 'djt', 'xmr', 'xrp' ], 'candidates harvested');
    main::process_vars_input([ [csi=>ord 'B'] ], $m);
    is($m->{vars}{highlight}, 1,     'Down moves the highlight');
    is($m->{vars}{field}, 'xmr',     'highlighted candidate copied into the field');
    is($m->{vars}{filter}, '',       'filter stays frozen while arrowing');
    main::process_vars_input([ [csi=>ord 'B'] ], $m);
    is($m->{vars}{field}, 'xrp',     'Down again -> next candidate');
    main::process_vars_input([ [csi=>ord 'B'] ], $m);
    is($m->{vars}{highlight}, 2,     'Down clamps at the last row');
    main::process_vars_input([ [csi=>ord 'A'] ], $m);
    is($m->{vars}{field}, 'xmr',     'Up walks back up the list');
};

subtest 'value selector: typing filters and resets the highlight' => sub {
    my $m = vars_edit_model('xmr', 'xrp');   # cands: djt, xmr, xrp
    main::process_vars_input([ [byte=>ord 'x'] ], $m);
    is($m->{vars}{field},  'x', 'char appended to the field');
    is($m->{vars}{filter}, 'x', 'filter follows the field on a typing keystroke');
    is($m->{vars}{highlight}, 0, 'highlight at the top after the first char');
    is_deeply([ main::vars_shown($m) ], [ 'xmr', 'xrp' ], 'shown narrowed to x-matches');
    main::process_vars_input([ [byte=>ord 'm'] ], $m);
    is($m->{vars}{filter}, 'xm', 'filter keeps following the field');
    is_deeply([ main::vars_shown($m) ], [ 'xmr' ], 'filter narrowed further to xm');
    # A typing keystroke snaps the highlight back to the top even after
    # an arrow moved it (the arrow also copies into the field, so the
    # filter then follows that combined text).
    $m = vars_edit_model('xmr', 'xrp');
    main::process_vars_input([ [byte=>ord 'x'] ], $m);   # shown=[xmr,xrp]
    main::process_vars_input([ [csi=>ord 'B'] ], $m);    # highlight 1
    is($m->{vars}{highlight}, 1, 'arrowed down within the filtered list');
    main::process_vars_input([ [byte=>ord 'q'] ], $m);   # any printable
    is($m->{vars}{highlight}, 0, 'highlight reset to the top by typing');
};

subtest 'value selector: arrow-then-type (field becomes prefix, filter follows)' => sub {
    my $m = vars_edit_model('xmr', 'xrp');   # cands: djt, xmr, xrp
    main::process_vars_input([ [csi=>ord 'B'] ], $m);   # highlight xmr, field=xmr
    is($m->{vars}{field}, 'xmr', 'arrow copied xmr into the field');
    main::process_vars_input([ [byte=>ord 'z'] ], $m);  # type onto the copied text
    is($m->{vars}{field},  'xmrz', 'typed char extends the arrowed-in value');
    is($m->{vars}{filter}, 'xmrz', 'filter now equals the field');
    is($m->{vars}{highlight}, 0,   'highlight reset by the typing keystroke');
    is_deeply([ main::vars_shown($m) ], [], 'nothing matches xmrz');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'v', 'xmrz' ], 'Enter applies the free-text field');
};

subtest 'value selector: empty field => Enter keeps the current value' => sub {
    my $m = vars_edit_model('xmr', 'xrp');   # cands: djt(current), xmr, xrp
    is($m->{vars}{field}, '', 'field empty on entry');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'v', 'djt' ],
        'empty field -> highlighted row (the current value) is applied');
};

subtest 'value selector: empty field after backspacing also keeps current' => sub {
    my $m = vars_edit_model('xmr', 'xrp');
    main::process_vars_input([ [byte=>ord 'x'] ], $m);   # field=x
    main::process_vars_input([ [byte=>0x7f] ], $m);      # backspace -> empty
    is($m->{vars}{field}, '', 'backspaced to empty');
    is($m->{vars}{highlight}, 0, 'highlight back at the top');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'v', 'djt' ], 'still applies the current value');
};

subtest 'value selector: literal field is not a dead zone (xm vs xmr)' => sub {
    my $m = vars_edit_model('xmr');          # cands: djt, xmr
    main::process_vars_input([ map { [byte=>ord $_] } split //, 'xm' ], $m);
    is($m->{vars}{field}, 'xm', 'field holds the literal typed text');
    is_deeply([ main::vars_shown($m) ], [ 'xmr' ], 'xmr shown as the suggestion');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'v', 'xm' ],
        'Enter applies the literal xm, not the shown xmr');
};

subtest 'value selector: arrowing to a suggestion then Enter applies it' => sub {
    my $m = vars_edit_model('xmr');          # cands: djt, xmr
    main::process_vars_input([ map { [byte=>ord $_] } split //, 'xm' ], $m);
    main::process_vars_input([ [csi=>ord 'B'] ], $m);    # highlight xmr, field=xmr
    is($m->{vars}{field}, 'xmr', 'arrow filled the field with the suggestion');
    my $action = main::process_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'var_set', 'v', 'xmr' ], 'now xmr is applied');
};

subtest 'value selector: a non-arrow CSI final is consumed, not typed' => sub {
    my $m = vars_edit_model('xmr', 'xrp');
    main::process_vars_input([ [csi=>ord 'H'] ], $m);    # Home, say
    is($m->{vars}{field}, '', 'CSI final byte not appended to the field');
    is($m->{vars}{highlight}, 0, 'highlight untouched');
};

subtest 'value selector: Esc cancels and clears the edit state' => sub {
    my $m = vars_edit_model('xmr', 'xrp');
    main::process_vars_input([ [csi=>ord 'B'] ], $m);    # field=xmr
    main::process_vars_input([ ['bare_esc'] ], $m);
    is($m->{vars}{edit}, 0, 'no longer editing');
    is($m->{vars}{field}, '', 'field cleared');
    is_deeply($m->{vars}{cands}, [], 'candidates cleared');
    is($m->{mode}, 'vars', 'still in the vars view');
};

# ---------------------------------------------------------------------------
# Feature A — union of unset rows
# ---------------------------------------------------------------------------

# A session whose single attachment carries $tmpl. Bare-bones: the unset
# derivation only reads attachments[].session_name_template.
sub tmpl_session {
    my ($name, $tmpl) = @_;
    return { name => $name,
             attachments => [ { session_name_template => $tmpl, pid => 1 } ] };
}

# Flatten a merged list to "name" / "name=value" / "name(unset)" tokens,
# in list order, for compact structural assertions.
sub merged_repr {
    return [ map { $_->{unset} ? "$_->{name}(unset)" : "$_->{name}=$_->{value}" }
             @{$_[0]} ];
}

subtest 'merge_unset_vars: referenced-but-absent names become unset rows, sorted' => sub {
    my $sessions = [
        tmpl_session('A-x', '{a}-x'),
        tmpl_session('B-x', '{b}-x'),
        tmpl_session('C-x', '{c}-x'),
    ];
    my $merged = main::merge_unset_vars([ { name => 'a', value => '1' } ], $sessions);
    is_deeply(merged_repr($merged), [ 'a=1', 'b(unset)', 'c(unset)' ],
        'set a kept; b,c surfaced as unset; re-sorted by name');
};

subtest 'merge_unset_vars: a set-and-referenced var stays a single set row' => sub {
    my $sessions = [ tmpl_session('1-x', '{a}-x') ];
    my $merged = main::merge_unset_vars([ { name => 'a', value => '1' } ], $sessions);
    is_deeply(merged_repr($merged), [ 'a=1' ], 'no synthetic row for a set var');
};

subtest 'merge_unset_vars: a var referenced by several templates yields one row' => sub {
    my $sessions = [
        tmpl_session('w-edit', '{w}-edit'),
        tmpl_session('w-term', '{w}-term'),
        tmpl_session('w-logs', '{w}-logs'),
    ];
    my $merged = main::merge_unset_vars([], $sessions);
    is_deeply(merged_repr($merged), [ 'w(unset)' ], 'multi-template -> one unset row');
};

subtest 'merge_unset_vars: a repeated token within one template de-dups' => sub {
    my $sessions = [ tmpl_session('a-a', '{a}-{a}') ];
    my $merged = main::merge_unset_vars([], $sessions);
    is_deeply(merged_repr($merged), [ 'a(unset)' ], '{a}-{a} -> one row');
};

subtest 'merge_unset_vars: a detached session (no attachments) surfaces nothing' => sub {
    my $sessions = [
        { name => 'detached-edit', attachments => [] },   # template invisible
        { name => 'plain',         attachments => [ { session_name_template => 'plain', pid => 1 } ] },
    ];
    my $merged = main::merge_unset_vars([ { name => 'a', value => '1' } ], $sessions);
    is_deeply(merged_repr($merged), [ 'a=1' ],
        'no templates on attached sessions -> no unset rows');
};

subtest 'merge_unset_vars: a set-but-empty var stays a set row, never flagged unset' => sub {
    # Even though the value is "", it is a real (set) row: an empty value
    # must not be confused with unset.
    my $sessions = [ tmpl_session('-x', '{a}-x') ];   # references {a}, which is set to ""
    my $merged = main::merge_unset_vars([ { name => 'a', value => '' } ], $sessions);
    is(scalar @$merged, 1, 'one row');
    ok(!$merged->[0]{unset}, 'set-but-empty var is not flagged unset');
    is($merged->[0]{value}, '', 'value stays the empty string');
};

# Build a vars-mode model carrying a real (set) list plus sessions; the
# merge runs so the displayed list mirrors what enter_vars_mode produces.
sub merged_vars_model {
    my ($real, $sessions) = @_;
    my $m = main::model_new();
    $m->{mode}     = 'vars';
    $m->{sessions} = $sessions;
    $m->{vars}{list} = main::merge_unset_vars($real, $sessions);
    $m->{vars}{sel}  = 0;
    return $m;
}

subtest 'remerge_vars: set one of two unset siblings; the other survives, cursor by name' => sub {
    # b and c are both unset siblings; the cursor sits on b. Replay the
    # successful-set sequence event_loop runs inline: fresh set rows
    # (b now set), cursor pointed at the promoted var, then a re-merge
    # against the (unchanged) sessions.
    my $sessions = [ tmpl_session('B-x', '{b}-x'), tmpl_session('C-x', '{c}-x') ];
    my $m = merged_vars_model([], $sessions);
    is_deeply(merged_repr($m->{vars}{list}), [ 'b(unset)', 'c(unset)' ], 'two unset siblings');
    $m->{vars}{sel} = 0;   # cursor on b

    # event_loop's post-set steps: refetch set rows, point cursor at the
    # var we just set, then remerge against fresh sessions.
    $m->{vars}{list} = [ { name => 'b', value => 'foo' } ];   # fresh `var list`
    ($m->{vars}{sel}) = grep { $m->{vars}{list}[$_]{name} eq 'b' }
        0 .. $#{$m->{vars}{list}};
    main::remerge_vars($m);

    is_deeply(merged_repr($m->{vars}{list}), [ 'b=foo', 'c(unset)' ],
        'b promoted to a set row; c survives as unset');
    is($m->{vars}{list}[$m->{vars}{sel}]{name}, 'b',
        'cursor stays on the promoted var by name across the resort');
};

subtest 'remerge_vars: a session refresh that introduces a referencing session adds the unset row' => sub {
    my $sessions = [ tmpl_session('B-x', '{b}-x') ];
    my $m = merged_vars_model([ { name => 'a', value => '1' } ], $sessions);
    is_deeply(merged_repr($m->{vars}{list}), [ 'a=1', 'b(unset)' ], 'a set, b unset');
    $m->{vars}{sel} = 1;   # cursor on b

    # A refresh brings in a session referencing a new var {c}.
    push @{$m->{sessions}}, tmpl_session('C-x', '{c}-x');
    main::remerge_vars($m);
    is_deeply(merged_repr($m->{vars}{list}), [ 'a=1', 'b(unset)', 'c(unset)' ],
        'c surfaced by the new session');
    is($m->{vars}{list}[$m->{vars}{sel}]{name}, 'b', 'cursor held on b by name');
};

subtest 'remerge_vars: a refresh dropping the only referencing session removes its unset row' => sub {
    my $sessions = [ tmpl_session('B-x', '{b}-x'), tmpl_session('C-x', '{c}-x') ];
    my $m = merged_vars_model([], $sessions);
    is_deeply(merged_repr($m->{vars}{list}), [ 'b(unset)', 'c(unset)' ], 'b,c unset');
    $m->{vars}{sel} = 0;   # cursor on b

    # c's session goes away; only b remains referenced.
    $m->{sessions} = [ tmpl_session('B-x', '{b}-x') ];
    main::remerge_vars($m);
    is_deeply(merged_repr($m->{vars}{list}), [ 'b(unset)' ], 'c row dropped with its session');
    is($m->{vars}{list}[$m->{vars}{sel}]{name}, 'b', 'cursor still on b');
};

subtest 'remerge_vars: cursor whose variable vanished clamps to the last row' => sub {
    my $sessions = [ tmpl_session('B-x', '{b}-x'), tmpl_session('C-x', '{c}-x') ];
    my $m = merged_vars_model([], $sessions);   # [b(unset), c(unset)]
    $m->{vars}{sel} = 1;   # cursor on c

    # c is no longer referenced AND not set: it disappears entirely.
    $m->{sessions} = [ tmpl_session('B-x', '{b}-x') ];
    main::remerge_vars($m);
    is_deeply(merged_repr($m->{vars}{list}), [ 'b(unset)' ], 'only b remains');
    is($m->{vars}{sel}, 0, 'cursor clamped into bounds');
};

subtest 'remerge_vars on an empty list does not autovivify a phantom row' => sub {
    # An empty vars list (no set vars, nothing referenced) must stay
    # empty across a re-merge — reading the cursor row must not conjure a
    # row into the array.
    my $m = merged_vars_model([], [
        { name => 'plain', attachments => [
            { session_name_template => 'plain', pid => 1 } ] } ]);
    is(scalar @{$m->{vars}{list}}, 0, 'list starts empty (nothing referenced)');
    main::remerge_vars($m);
    is(scalar @{$m->{vars}{list}}, 0, 'still empty after remerge — no phantom row');
    is($m->{vars}{sel}, 0, 'cursor pinned at 0');
};

subtest 'refresh_sessions in vars mode re-derives the list and keeps the cursor by name' => sub {
    # Drive the A.3c wiring: refresh_sessions, with a session list that
    # introduces a new referencing session, must re-merge the unset rows
    # while in vars mode and preserve the cursor.
    my $sessions = [ tmpl_session('B-x', '{b}-x') ];
    my $m = merged_vars_model([ { name => 'a', value => '1' } ], $sessions);
    $m->{vars}{sel} = 1;   # cursor on b(unset)

    no warnings qw(redefine once);
    local *main::fetch_sessions = sub {
        return [ tmpl_session('B-x', '{b}-x'), tmpl_session('C-x', '{c}-x') ];
    };
    main::refresh_sessions($m);
    is_deeply(merged_repr($m->{vars}{list}), [ 'a=1', 'b(unset)', 'c(unset)' ],
        'refresh_sessions re-merged the unset rows from the new session list');
    is($m->{vars}{list}[$m->{vars}{sel}]{name}, 'b',
        'cursor preserved by name through the refresh');
};

# ---------------------------------------------------------------------------
# No-regression (A.1): the resolution map fed to resolve_template /
# candidate_values must exclude synthetic unset rows, at both build sites.
# ---------------------------------------------------------------------------

subtest 'resolution_map drops unset rows so only real values resolve' => sub {
    my @list = (
        { name => 'editor', value => 'vim' },
        { name => 'workspace', unset => 1 },
    );
    my %map = main::resolution_map(@list);
    is_deeply(\%map, { editor => 'vim' },
        'unset row contributes no key (no synthetic editor="" either)');
};

subtest 'map-unchanged (candidate_values): an unset co-var does not perturb the harvest' => sub {
    # workspace is set; editor is an unset co-var in the template. The
    # candidate harvest for workspace must match the result with no unset
    # row present at all (editor stays literal, so {editor}-* prefixes
    # never spuriously match and collapse).
    my $sessions = [
        { name => '{editor}-myproj', attachments => [
            { session_name_template => '{editor}-{workspace}', pid => 1 } ] },
        { name => '{editor}-demo', attachments => [] },
    ];
    my $merged = main::merge_unset_vars(
        [ { name => 'workspace', value => 'myproj' } ], $sessions);
    # editor is referenced but unset -> present as a synthetic row.
    ok( (grep { $_->{name} eq 'editor' && $_->{unset} } @$merged),
        'editor surfaced as an unset row in the merged list');

    my %map_union = main::resolution_map(@$merged);
    my @with_union = main::candidate_values($sessions, \%map_union, 'workspace');

    # Pre-union baseline: the real rows only.
    my %map_real = main::resolution_map({ name => 'workspace', value => 'myproj' });
    my @pre_union = main::candidate_values($sessions, \%map_real, 'workspace');

    is_deeply(\@with_union, \@pre_union,
        'candidate harvest is identical with vs. without the unset row');
    # And concretely: {editor} stayed literal, so "{editor}-" is the prefix.
    is_deeply(\@with_union, [ 'myproj', 'demo' ],
        'captures are the remainders after the literal {editor}- prefix');
};

subtest 'map-unchanged (preview): a template with an unset co-var renders the var literal' => sub {
    # The preview for a set var (workspace) whose template also mentions an
    # unset var (editor) must leave {editor} literal — not collapse it to
    # empty. Render the browse frame and assert the literal token survives.
    my $sessions = [
        { name => '{editor}-myproj', attachments => [
            { session_name_template => '{editor}-{workspace}', pid => 1 } ] },
    ];
    my $m = main::model_new();
    $m->{mode}     = 'vars';
    $m->{sessions} = $sessions;
    $m->{vars}{list} = main::merge_unset_vars(
        [ { name => 'workspace', value => 'myproj' } ], $sessions);
    # Point the cursor at the set var so its preview is the one rendered.
    ($m->{vars}{sel}) = grep { $m->{vars}{list}[$_]{name} eq 'workspace' }
        0 .. $#{$m->{vars}{list}};
    my $out = strip_ansi( main::render($m, 80, 14) );
    like($out, qr/\{editor\}-myproj/,
        'unknown {editor} stays literal in the resolved preview, not collapsed to -myproj');
    unlike($out, qr/(?<![{}\w])-myproj(?![\w])/,
        'no empty-collapsed "-myproj" name appears');
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

subtest 'golden: vars view (editing — value selector, layout C)' => sub {
    my $m = main::model_new();
    $m->{mode}  = 'vars';
    $m->{vars}{list} = [ { name => 'editor', value => 'vim' },
                    { name => 'workspace', value => 'myproj' } ];
    $m->{vars}{sel}  = 1;
    $m->{sessions} = [
        { name => 'myproj-edit', attachments => [ { session_name_template => '{workspace}-edit', pid => 111 } ] },
        { name => 'myproj-term', attachments => [ { session_name_template => '{workspace}-term', pid => 222 } ] },
        { name => 'vim-notes',   attachments => [ { session_name_template => '{editor}-notes',   pid => 333 } ] },
        { name => 'demo-edit',   attachments => [] },   # detached: a candidate target
    ];
    main::vars_edit_start($m);                            # field='', highlight=myproj
    main::process_vars_input([ [csi=>ord 'B'] ], $m);    # highlight -> demo
    # Body: variable list, the candidate list (highlighted row marked),
    # then the highlighted candidate's per-attachment re-dial preview.
    frame_is(main::render($m, 72, 14), <<'GOLDEN', 'vars editing frame');
                             variables (2)
   editor    = vim   (1 session)
 > workspace = myproj   (2 sessions)
  candidate values:
   myproj
 > demo

  {workspace} attachments:
    {workspace}-edit         myproj-edit      pid 111  -> demo-edit
    {workspace}-term         myproj-term      pid 222  -> demo-term
  set workspace = demo_   (ret: apply, esc: cancel)
GOLDEN
};

subtest 'golden: vars view with an unset row beside a set row' => sub {
    # editor is set and referenced (its preview is the rendered one);
    # workspace is referenced by an attached template but absent from
    # `var list`, so it surfaces as a dimmed (unset) row with its own
    # session count. ASCII names — the name column is byte-measured.
    my $m = main::model_new();
    $m->{mode}  = 'vars';
    my $sessions = [
        { name => 'vim-notes',   attachments => [ { session_name_template => '{editor}-notes',   pid => 333 } ] },
        { name => 'myproj-edit', attachments => [ { session_name_template => '{workspace}-edit', pid => 111 } ] },
    ];
    $m->{vars}{list} = main::merge_unset_vars(
        [ { name => 'editor', value => 'vim' } ], $sessions);
    $m->{vars}{sel}  = 0;          # editor (set), sorts first
    $m->{sessions}   = $sessions;
    frame_is(main::render($m, 72, 12), <<'GOLDEN', 'vars unset-row frame');
                             variables (2)
 > editor    = vim   (1 session)
   workspace   (unset)   (1 session)

  {editor} attachments:
    {editor}-notes           vim-notes        pid 333
  j/k: select, e: set value, esc: back
GOLDEN
};

subtest 'shell-out argv guards dash-led names and values with --' => sub {
    is_deeply([ main::attach_cmd('-sh', 0) ],
        [ 'shpool', 'attach', '--', '-sh' ],
        'attach inserts -- before a dash-led name');
    is_deeply([ main::attach_cmd('-sh', 1) ],
        [ 'shpool', 'attach', '-f', '--', '-sh' ],
        'attach keeps -f ahead of the -- separator');
    is_deeply([ main::kill_cmd('-sh') ],
        [ 'shpool', 'kill', '--', '-sh' ],
        'kill inserts -- before a dash-led name');
    is_deeply([ main::var_set_cmd('coin', '-xmr') ],
        [ 'shpool', 'var', 'set', '--', 'coin', '-xmr' ],
        'var set inserts -- before the name and value');
};

# ---------------------------------------------------------------------------
# Feature B — create-time variable prompt
# ---------------------------------------------------------------------------

subtest 'unknown_template_vars: tokens minus known, order preserved' => sub {
    is_deeply([ main::unknown_template_vars('plainsess', {}) ], [],
        'no tokens -> nothing unknown');
    is_deeply([ main::unknown_template_vars('{a}-x', {}) ], ['a'],
        'one token, none known');
    is_deeply([ main::unknown_template_vars('{a}-{b}-{c}', {}) ], ['a','b','c'],
        'many tokens, first-seen order');
    is_deeply(
        [ main::unknown_template_vars('{a}-{b}-{c}', { b => 'set' }) ],
        ['a','c'],
        'a known middle var is dropped, the rest keep order');
    is_deeply(
        [ main::unknown_template_vars('{a}-{b}', { a => 'x', b => 'y' }) ],
        [],
        'all known -> nothing to prompt');
    is_deeply([ main::unknown_template_vars('{a}-{b}-{a}', {}) ], ['a','b'],
        'a repeated token is de-duped (template_vars order)');
    # A var set to the empty string still counts as known (exists, not
    # truthiness) — mustn't re-prompt for it.
    is_deeply([ main::unknown_template_vars('{a}-x', { a => '' }) ], [],
        'a set-but-empty var is known, not prompted');
};

# ---------------------------------------------------------------------------
# B.1 dup-check in the pure create handler: a duplicate name errors with
# no ['create'] action emitted (so detection/prompt never run) and no var
# is set. make_model carries sessions foo + bar.
# ---------------------------------------------------------------------------

subtest 'process_create_input: duplicate name errors, emits no create action' => sub {
    my $m = make_model();
    $m->{mode}      = 'create';
    $m->{mode_data} = 'foo';      # already a session
    my $action = main::process_create_input([ [byte=>0x0d] ], $m);
    is($action, undef, 'no action emitted for a duplicate name');
    is($m->{mode}, 'normal', 'returned to normal mode');
    is($m->{var_prompt}, undef, 'no prompt opened');
    like($m->{error}, qr/foo.*already exists/, 'error names the duplicate');
};

subtest 'process_create_input: a fresh name still emits a create action' => sub {
    my $m = make_model();
    $m->{mode}      = 'create';
    $m->{mode_data} = 'brandnew';
    my $action = main::process_create_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'create', 'brandnew' ],
        'a non-duplicate name emits [create, name] (detect runs in event_loop)');
    is($m->{mode}, 'normal', 'mode reset to normal as the action propagates');
};

# ---------------------------------------------------------------------------
# B.6 prompt state machine. Build the model the way event_loop's detect
# step does: stash name + ordered unknowns + the set-vars map.
# ---------------------------------------------------------------------------

sub make_var_prompt_model {
    my ($name, $vars, $set) = @_;
    my $m = main::model_new();
    $m->{mode}       = 'create_vars';
    $m->{var_prompt} = {
        name      => $name,
        vars      => $vars,
        idx       => 0,
        input     => '',
        collected => [],
        set_vars  => $set // {},
    };
    return $m;
}

sub type { return map { [ byte => ord $_ ] } split //, $_[0] }

subtest 'create_vars prompt: a single unknown var collects then emits' => sub {
    my $m = make_var_prompt_model('{a}-x', ['a']);
    my $action = main::process_create_vars_input([ type('hello') ], $m);
    is($action, undef, 'still collecting after typing');
    is($m->{var_prompt}{input}, 'hello', 'input accumulates printable bytes');
    $action = main::process_create_vars_input([ [byte=>0x0d] ], $m);
    is_deeply($action, [ 'create_vars', '{a}-x', [ ['a','hello'] ] ],
        'Enter on the last var emits the apply action with the pair');
    is($m->{mode}, 'normal', 'dropped to normal mode at apply-emit (B.4)');
    is($m->{var_prompt}, undef, 'prompt state torn down');
};

subtest 'create_vars prompt: multiple unknowns collected in order' => sub {
    my $m = make_var_prompt_model('{a}-{b}', ['a','b']);
    main::process_create_vars_input([ type('one'), [byte=>0x0d] ], $m);
    is($m->{mode}, 'create_vars', 'still prompting after the first var');
    is($m->{var_prompt}{idx}, 1, 'advanced to the second var');
    is($m->{var_prompt}{input}, '', 'input reset for the next var');
    is_deeply($m->{var_prompt}{collected}, [ ['a','one'] ], 'first pair stored');
    my $action = main::process_create_vars_input([ type('two'), [byte=>0x0d] ], $m);
    is_deeply($action, [ 'create_vars', '{a}-{b}', [ ['a','one'], ['b','two'] ] ],
        'both pairs emitted in template order');
    is($m->{mode}, 'normal', 'normal mode at emit');
};

subtest 'create_vars prompt: an empty entry skips that var (stays unset)' => sub {
    my $m = make_var_prompt_model('{a}-{b}', ['a','b']);
    # Enter on an empty input for 'a' -> skip it.
    main::process_create_vars_input([ [byte=>0x0d] ], $m);
    is($m->{var_prompt}{idx}, 1, 'advanced past the skipped var');
    is_deeply($m->{var_prompt}{collected}, [], 'nothing collected for the empty entry');
    my $action = main::process_create_vars_input([ type('bee'), [byte=>0x0d] ], $m);
    is_deeply($action, [ 'create_vars', '{a}-{b}', [ ['b','bee'] ] ],
        'only the non-empty var is in the emitted pairs');
};

subtest 'create_vars prompt: all entries skipped emits an empty pair list' => sub {
    my $m = make_var_prompt_model('{a}-{b}', ['a','b']);
    main::process_create_vars_input([ [byte=>0x0d] ], $m);   # skip a
    my $action = main::process_create_vars_input([ [byte=>0x0d] ], $m);   # skip b
    is_deeply($action, [ 'create_vars', '{a}-{b}', [] ],
        'all-skip -> [create_vars, name, []] (attach with the name resolving empty)');
    is($m->{mode}, 'normal', 'normal mode at emit');
};

subtest 'create_vars prompt: Backspace edits the in-progress input' => sub {
    my $m = make_var_prompt_model('{a}', ['a']);
    main::process_create_vars_input([ type('abc'), [byte=>0x7f] ], $m);
    is($m->{var_prompt}{input}, 'ab', 'Backspace removes the last char');
};

subtest 'create_vars prompt: Esc cancels — nothing collected, no action' => sub {
    my $m = make_var_prompt_model('{a}-{b}', ['a','b']);
    main::process_create_vars_input([ type('partial') ], $m);
    my $action = main::process_create_vars_input([ ['bare_esc'] ], $m);
    is($action, undef, 'Esc emits no action');
    is($m->{mode}, 'normal', 'Esc returns to normal mode');
    is($m->{var_prompt}, undef, 'prompt state cleared (nothing set)');
};

subtest 'create_vars prompt: Ctrl-C cancels like Esc' => sub {
    my $m = make_var_prompt_model('{a}', ['a']);
    my $action = main::process_create_vars_input([ [byte=>0x03] ], $m);
    is($action, undef, 'Ctrl-C emits no action');
    is($m->{mode}, 'normal', 'returned to normal mode');
    is($m->{var_prompt}, undef, 'prompt state cleared');
};

subtest 'create_vars prompt: arrow/CSI keys are ignored mid-prompt' => sub {
    my $m = make_var_prompt_model('{a}', ['a']);
    main::process_create_vars_input([ [csi=>ord 'B'], [csi=>ord 'A'] ], $m);
    is($m->{var_prompt}{input}, '', 'CSI final bytes are not typed into the input');
    is($m->{var_prompt}{idx}, 0, 'still on the first var');
};

# ---------------------------------------------------------------------------
# B.3 detect decision (the inline event_loop computation): which vars a
# new name needs prompting for, against the set-var map. None -> attach
# directly; some -> prompt. Asserted via the decision helper the detect
# step calls.
# ---------------------------------------------------------------------------

subtest 'detect: a name with all-known vars needs no prompt' => sub {
    my %set = ( a => '1', b => '2' );
    is_deeply([ main::unknown_template_vars('{a}-{b}', \%set) ], [],
        'every referenced var is set -> detect falls through to attach');
};

subtest 'detect: a name with an unknown var yields the prompt list' => sub {
    my %set = ( a => '1' );
    is_deeply([ main::unknown_template_vars('{a}-{b}-{c}', \%set) ], ['b','c'],
        'the unset referenced vars, in order, drive the prompt');
};

subtest 'detect: a plain name (no vars) needs no prompt' => sub {
    is_deeply([ main::unknown_template_vars('plainname', { a => '1' }) ], [],
        'no template vars -> nothing to prompt, attach directly');
};

# ---------------------------------------------------------------------------
# B.6 render: the create-prompt bottom bar shows the asked var, the typed
# input, and a live name preview. A still-to-be-prompted var must render
# as the literal {name} (not collapsed to empty); the resolved-so-far
# vars (set + collected + current) are substituted.
# ---------------------------------------------------------------------------

subtest 'create_vars_label: shows the var, input, and a live preview' => sub {
    my $m = make_var_prompt_model('{a}-{b}', ['a','b'], {});
    $m->{var_prompt}{input} = 'foo';
    my $text = label_text( main::create_vars_label($m->{var_prompt}) );
    like($text, qr/set value for a:/, 'prompts for the current var');
    like($text, qr/foo/, 'echoes the typed input');
    # The current var resolves to the input; the future var {b} stays literal.
    like($text, qr/foo-\{b\}/,
        'preview substitutes the current var and leaves the future var literal');
    like($text, qr/ret: next/, 'hint says "next" while more vars remain');
};

subtest 'create_vars_label: a future var is never collapsed to empty' => sub {
    # On the FIRST var, the second is still unknown: it must not be folded
    # in as empty (which would mis-preview "foo-" for "{a}-{b}").
    my $m = make_var_prompt_model('{a}-{b}', ['a','b'], {});
    $m->{var_prompt}{input} = 'foo';
    my $text = label_text( main::create_vars_label($m->{var_prompt}) );
    unlike($text, qr/(?<!\{)foo-(?!\{)(?:\s|$|\()/,
        'no "foo-" collapsed preview (the {b} token survives)');
};

subtest 'create_vars_label: collected + set vars feed the preview, last says create' => sub {
    # Asking for the final var 'b'; 'a' was already collected as "ay" and
    # 'c' is a pre-set var. The preview resolves all three.
    my $m = make_var_prompt_model('{a}-{b}-{c}', ['a','b'], { c => 'see' });
    $m->{var_prompt}{idx}       = 1;             # now on 'b'
    $m->{var_prompt}{collected} = [ ['a','ay'] ];
    $m->{var_prompt}{input}     = 'bee';
    my $text = label_text( main::create_vars_label($m->{var_prompt}) );
    like($text, qr/set value for b:/, 'prompting for the second var');
    like($text, qr/ay-bee-see/,
        'preview = collected a + current b + pre-set c');
    like($text, qr/ret: create/, 'hint says "create" on the last var');
};

# ---------------------------------------------------------------------------
# B.6 wiring: bottom_bar_label routes create_vars and outranks an error.
# ---------------------------------------------------------------------------

subtest 'bottom_bar_label: create_vars prompt outranks a parked error' => sub {
    my $m = make_model();
    $m->{mode}       = 'create_vars';
    $m->{var_prompt} = {
        name => '{a}-x', vars => ['a'], idx => 0,
        input => 'typing', collected => [], set_vars => {},
    };
    $m->{error} = 'background error msg';
    my $text = label_text( main::bottom_bar_label($m) );
    like($text,   qr/set value for a:/,     'prompt label selected');
    like($text,   qr/typing/,               'typed input visible');
    unlike($text, qr/background error msg/, 'error hidden behind the modal prompt');
};

subtest 'render: create_vars prompt renders over the session list, hiding errors' => sub {
    my $m = make_model();
    $m->{mode}       = 'create_vars';
    $m->{var_prompt} = {
        name => '{a}-x', vars => ['a'], idx => 0,
        input => 'wsname', collected => [], set_vars => {},
    };
    $m->{error} = "session 'foo' is gone";
    my $out = strip_ansi( main::render($m, 80, 24) );
    like($out,   qr/set value for a:/, 'prompt shown in the bottom bar');
    like($out,   qr/wsname/,           'typed input visible in the frame');
    like($out,   qr/\bfoo\b/,          'session list still rendered behind the prompt');
    unlike($out, qr/foo' is gone/,     'error not shown over the prompt');
};

subtest 'mid-prompt refresh_sessions leaves the create_vars prompt intact' => sub {
    # A background refresh (events/focus) during the prompt only touches
    # the session list — mode and var_prompt must survive untouched.
    my $m = make_var_prompt_model('{a}-x', ['a'], {});
    $m->{var_prompt}{input} = 'half';
    no warnings qw(redefine once);
    local *main::fetch_sessions = sub { [ session_record('other', 500) ] };
    main::refresh_sessions($m);
    is($m->{mode}, 'create_vars', 'still in the prompt mode after a refresh');
    ok($m->{var_prompt}, 'prompt state preserved');
    is($m->{var_prompt}{input}, 'half', 'the in-progress input survives');
    is($m->{var_prompt}{idx}, 0, 'prompt position unchanged');
};

# ---------------------------------------------------------------------------
# parse_args: the optional SESSION positional
# ---------------------------------------------------------------------------

# parse_args reads the global @ARGV and dies on a usage error; each case
# localizes @ARGV and traps the die.
sub parse_argv {
    my @argv = @_;
    local @ARGV = @argv;
    my $session = eval { main::parse_args() };
    return ($session, $@);
}

subtest 'parse_args: no positional means no startup target' => sub {
    my ($session, $err) = parse_argv();
    is($err,     '',    'no error');
    is($session, undef, 'session is undef');
};

subtest 'parse_args: a single positional is the session name' => sub {
    my ($session, $err) = parse_argv('work');
    is($err,     '',     'no error');
    is($session, 'work', 'session name returned');
};

subtest 'parse_args: flags and a positional coexist' => sub {
    # Getopt::Long permutes by default, so the positional may sit either
    # side of the flags.
    my ($before, $e1) = parse_argv('--socket', '/tmp/s', 'work');
    is($e1,     '',     'no error with the name last');
    is($before, 'work', 'name found after flags');

    my ($after, $e2) = parse_argv('work', '--socket', '/tmp/s');
    is($e2,    '',     'no error with the name first');
    is($after, 'work', 'name found before flags');
};

subtest 'parse_args: a second positional is a usage error' => sub {
    my ($session, $err) = parse_argv('work', 'extra');
    like($err, qr/unexpected argument/, 'dies with a usage error');
    unlike($err, qr/\bwork\b/, 'the accepted name is not blamed, only the extras');
    like($err, qr/\bextra\b/, 'the offending argument is named');
};

subtest 'parse_args: an empty session name is rejected' => sub {
    # `shp host ""` would otherwise reach shpool as an empty name.
    my ($session, $err) = parse_argv('');
    like($err, qr/empty session name/, 'dies rather than attaching to ""');
};

# ---------------------------------------------------------------------------
# `shperl SESSION` startup attach — run_tui dispatches this through the
# ordinary attach action, so these assert the action's decisions given a
# startup name. shell_attach is stubbed out (it would shell out to
# `shpool attach` and hand it the tty).
# ---------------------------------------------------------------------------

# Dispatch a startup name exactly as run_tui does, against a stubbed
# session list. Returns the model plus the shell_attach calls recorded.
sub startup_attach {
    my ($name, @sessions) = @_;
    my $m = main::model_new();
    my @attached;
    no warnings qw(redefine once);
    local *main::fetch_sessions = sub { [ @sessions ] };
    local *main::shell_attach   = sub {
        my (undef, $n, $force) = @_;
        push @attached, { name => $n, force => $force ? 1 : 0 };
        return 1;
    };
    $main::ACTION_HANDLER{attach}->($m, $name);
    return ($m, \@attached);
}

# session_record() builds a Disconnected row; fetch_sessions normally
# derives `attached` from the status string at the JSON boundary, so a
# stubbed list has to set it itself.
sub attached_record {
    my ($name, $ts) = @_;
    my $s = session_record($name, $ts);
    $s->{status}   = 'Attached';
    $s->{attached} = 1;
    return $s;
}

subtest 'shperl SESSION attaches when the session exists and is free' => sub {
    my ($m, $calls) = startup_attach('foo', session_record('foo', 100));
    is(scalar @$calls, 1,       'attached once');
    is($calls->[0]{name},  'foo', 'attached to the named session');
    is($calls->[0]{force}, 0,     'without force');
    is($m->{mode}, 'normal', 'lands in the table, not a modal');
    is($m->{error}, undef,   'no error parked');
};

subtest 'shperl SESSION on an attached session prompts before stealing' => sub {
    # Equivalent to pressing Enter on a row marked attached: the
    # confirm_force modal, never a silent -f steal.
    my ($m, $calls) = startup_attach('foo', attached_record('foo', 100));
    is(scalar @$calls, 0, 'nothing attached yet');
    is($m->{mode},      'confirm_force', 'promoted to the force-confirm modal');
    is($m->{mode_data}, 'foo',           'modal targets the named session');
};

subtest 'shperl SESSION with an unknown name parks an error and shows the table' => sub {
    # Strict equivalence with the table: you cannot Enter-attach a row
    # that is not there, so an unknown name does not silently create.
    my ($m, $calls) = startup_attach('nope', session_record('foo', 100));
    is(scalar @$calls, 0, 'nothing attached');
    like($m->{error}, qr/nope/, 'error names the missing session');
    is($m->{mode}, 'normal', 'drops into the table');
};

subtest 'shperl SESSION does not attach when the session list fails' => sub {
    # Deliberately not asserting *which* error survives. refresh_sessions
    # parks "shpool list: daemon down" and returns without populating the
    # list, then session_or_error overwrites it with "session 'foo' is
    # gone" -- a pre-existing clobber on the shared attach path (the same
    # thing happens pressing Enter), so pinning the message here would
    # freeze a wart this change didn't introduce.
    my $m = main::model_new();
    my @attached;
    no warnings qw(redefine once);
    local *main::fetch_sessions = sub { die "daemon down\n" };
    local *main::shell_attach   = sub { push @attached, $_[1]; 1 };
    $main::ACTION_HANDLER{attach}->($m, 'foo');
    is(scalar @attached, 0, 'nothing attached');
    ok(defined $m->{error}, 'an error is parked rather than a silent no-op');
};

done_testing();
