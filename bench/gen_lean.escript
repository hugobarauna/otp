#!/usr/bin/env escript
%% Generate "codegen-heavy" modules: many functions with real computation
%% (arithmetic, comparisons, guards, local/remote calls, pattern matching)
%% but LEAN on unique atoms and literals — closer to large real-world
%% modules (generated parsers, protocol handlers, numeric code) where JIT
%% code generation, not atom-table/literal parsing, dominates load time.
%%
%% Usage: gen_lean.escript <count> <funcs_per_module> <outdir>

main([CountS, FuncsS, OutDir]) ->
    Count = list_to_integer(CountS),
    Funcs = list_to_integer(FuncsS),
    ok = filelib:ensure_dir(filename:join(OutDir, "x")),
    lists:foreach(fun(I) -> gen(I, Funcs, OutDir) end, lists:seq(1, Count)),
    io:format("generated ~p lean modules in ~s~n", [Count, OutDir]).

gen(I, Funcs, OutDir) ->
    Name = io_lib:format("lean_mod_~3..0b", [I]),
    File = filename:join(OutDir, Name ++ ".erl"),
    Exports = lists:join(", ", [io_lib:format("f~b/2", [K])
                                || K <- lists:seq(1, Funcs)]),
    Hdr = io_lib:format("-module(~s).~n-export([~s, run/1]).~n~n",
                        [Name, Exports]),
    Run = ["run(X) ->\n    f1(X, X)",
           [io_lib:format(" + f~b(X, ~b)", [K, K])
            || K <- lists:seq(2, min(Funcs, 40))],
           ".\n\n"],
    Body = [func(K, Funcs) || K <- lists:seq(1, Funcs)],
    ok = file:write_file(File, [Hdr, Run, Body]).

%% Shared atoms only (ok/error/lt/eq/gt/even/odd); lots of branches, guards,
%% arithmetic and local calls -> many BEAM instructions, few literals/atoms.
func(K, Funcs) ->
    N1 = (K rem Funcs) + 1,
    N2 = ((K + 1) rem Funcs) + 1,
    io_lib:format(
        "f~b(A, B) when A > B, A > 0 ->\n"
        "    C = A * ~b + B - ~b,\n"
        "    case C rem 4 of\n"
        "        0 -> g~b(C, A);\n"
        "        1 -> g~b(C bsr 1, B);\n"
        "        2 -> {ok, C + f~b(B, A - 1)};\n"
        "        _ -> {error, C bxor A}\n"
        "    end;\n"
        "f~b(A, B) when A =< B ->\n"
        "    case A + B of\n"
        "        S when S < 10 -> g~b(S, A);\n"
        "        S when S < 100 -> g~b(S * 2, B);\n"
        "        S -> S - ~b\n"
        "    end;\n"
        "f~b(A, _) -> g~b(A, A).\n\n"
        "g~b(X, Y) when X > Y -> X - Y * ~b;\n"
        "g~b(X, Y) when X < Y -> Y - X + ~b;\n"
        "g~b(X, _) -> X bsl 1.\n\n",
        [K, K, K, N1, N2, N1,
         K, N1, N2, K,
         K, K,
         K, K, K, K, K]).
