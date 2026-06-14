#!/usr/bin/env escript
%% Load the first N .beam files (sorted) from a dir; print microseconds.
%% Usage: lb_count.escript <dir> <count>
main([Dir, CountS]) ->
    Count = list_to_integer(CountS),
    All = lists:sort(filelib:wildcard(filename:join(Dir, "*.beam"))),
    Files = lists:sublist(All, Count),
    Mods = [begin {ok,B} = file:read_file(F),
                  {list_to_atom(filename:basename(F,".beam")), B} end
            || F <- Files],
    length(Mods) =:= Count orelse halt(2),
    T0 = erlang:monotonic_time(microsecond),
    [{module,M} = erlang:load_module(M,B) || {M,B} <- Mods],
    io:format("~b~n", [erlang:monotonic_time(microsecond) - T0]),
    halt(0).
