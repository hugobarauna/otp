#!/usr/bin/env escript
%% Time loading of all .beam files in a directory, in a fresh VM.
%% Usage: load_bench.escript <ebindir> [mode]
%%   mode = load     : erlang:load_module/2 per module (default; the
%%                     real-world sequential path: prepare + finish each)
%%   mode = prepare  : erlang:prepare_loading/2 only (parse + JIT codegen)
%%   mode = finish   : prepare all first (untimed), then time one batched
%%                     erlang:finish_loading/1 (staging commit)
%% Prints a single integer: elapsed microseconds.

main([Dir]) -> main([Dir, "load"]);
main([Dir, Mode]) ->
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.beam"))),
    Mods = [begin
                {ok, Bin} = file:read_file(F),
                Mod = list_to_atom(filename:basename(F, ".beam")),
                {Mod, Bin}
            end || F <- Files],
    length(Mods) > 0 orelse halt(2),
    Us = run(Mode, Mods),
    io:format("~b~n", [Us]),
    halt(0).

run("load", Mods) ->
    T0 = erlang:monotonic_time(microsecond),
    [{module, M} = erlang:load_module(M, B) || {M, B} <- Mods],
    erlang:monotonic_time(microsecond) - T0;
run("prepare", Mods) ->
    T0 = erlang:monotonic_time(microsecond),
    [true = is_reference(erlang:prepare_loading(M, B)) || {M, B} <- Mods],
    erlang:monotonic_time(microsecond) - T0;
run("finish", Mods) ->
    Prepared = [erlang:prepare_loading(M, B) || {M, B} <- Mods],
    T0 = erlang:monotonic_time(microsecond),
    ok = erlang:finish_loading(Prepared),
    erlang:monotonic_time(microsecond) - T0.
