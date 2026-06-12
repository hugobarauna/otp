#!/usr/bin/env escript
%% Generate N benchmark modules with many functions each.
%% Usage: gen_modules.escript <count> <funcs_per_module> <outdir>
%%
%% The modules are designed to exercise the loader: many functions
%% (export/import tables, lambda-free), many unique atoms, literals
%% (strings, binaries, maps, tuples, lists), guards, pattern matching,
%% local and remote calls, and line tables.

main([CountS, FuncsS, OutDir]) ->
    Count = list_to_integer(CountS),
    Funcs = list_to_integer(FuncsS),
    ok = filelib:ensure_dir(filename:join(OutDir, "x")),
    lists:foreach(fun(I) -> gen_module(I, Funcs, OutDir) end,
                  lists:seq(1, Count)),
    io:format("generated ~p modules in ~s~n", [Count, OutDir]).

gen_module(I, Funcs, OutDir) ->
    Name = io_lib:format("bench_mod_~3..0b", [I]),
    File = filename:join(OutDir, Name ++ ".erl"),
    Exports = lists:join(",\n         ",
        [io_lib:format("f_~b/1, g_~b/2", [K, K]) || K <- lists:seq(1, Funcs)]),
    Header = io_lib:format(
        "-module(~s).~n"
        "-export([~s,~n         data/0, dispatch/2]).~n~n"
        "data() ->~n    ~s.~n~n"
        "~s"
        "dispatch(_, X) -> {unknown, X}.~n~n",
        [Name, Exports, big_literal(I), dispatch_clauses(I, Funcs)]),
    Body = [function(I, K, Funcs) || K <- lists:seq(1, Funcs)],
    ok = file:write_file(File, [Header, Body]).

%% A sizable literal term per module: exercises the literal chunk
%% (compressed) and literal decoding at load time.
big_literal(I) ->
    Pairs = [io_lib:format("{key_~b_~b, ~b}", [I, J, I * J]) || J <- lists:seq(1, 30)],
    Map = ["#{", lists:join(", ",
            [io_lib:format("field_~b_~b => \"value string ~b ~b\"", [I, J, I, J])
             || J <- lists:seq(1, 15)]), "}"],
    ["{", lists:join(",\n     ", Pairs), ",\n     ", Map, ",\n     ",
     io_lib:format("<<\"module ~b binary literal with some padding data\">>", [I]),
     "}"].

dispatch_clauses(I, Funcs) ->
    [io_lib:format("dispatch(~b, X) -> f_~b(X);~n", [K, K])
     || K <- lists:seq(1, min(Funcs, 25))] ++
    [io_lib:format("dispatch(atom_~b_~b, X) -> g_~b(X, ~b);~n", [I, K, K, K])
     || K <- lists:seq(1, min(Funcs, 25))].

%% Each function: several clauses with different match constructs,
%% unique atoms, string/binary literals, guards, local + remote calls.
function(I, K, Funcs) ->
    Next = (K rem Funcs) + 1,
    io_lib:format(
        "f_~b(0) -> result_atom_~b_~b;~n"
        "f_~b(N) when is_integer(N), N > 0 -> N * ~b + ~b;~n"
        "f_~b([H | T]) -> [H bxor ~b | f_~b(T)];~n"
        "f_~b({pair_~b, A, B}) -> {ok_~b, A + B * ~b};~n"
        "f_~b(#{key_~b := V}) -> g_~b(V, ~b);~n"
        "f_~b(<<A:8, Rest/binary>>) -> {A, byte_size(Rest), ~b};~n"
        "f_~b(X) -> {error_~b_~b, X, \"clause fallthrough in module ~b fun ~b\"}.~n~n"
        "g_~b(V, Acc) when is_list(V) -> lists:sum([Acc | V]);~n"
        "g_~b(V, Acc) when is_map(V) -> maps:get(some_key_~b, V, Acc);~n"
        "g_~b(V, Acc) when is_binary(V) -> erlang:byte_size(V) + Acc;~n"
        "g_~b(V, Acc) when is_tuple(V) -> erlang:tuple_size(V) * Acc;~n"
        "g_~b(V, Acc) -> {fallback_~b_~b, V, Acc, <<\"g binary ~b ~b\">>}.~n~n",
        [K, I, K,
         K, K, I,
         K, K, K,
         K, K, K, I,
         K, K, Next, K,
         K, K,
         K, I, K, I, K,
         K,
         K, K,
         K,
         K,
         K, I, K, I, K]).
