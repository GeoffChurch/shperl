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

done_testing();
