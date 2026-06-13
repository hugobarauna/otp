#!/usr/bin/env escript
%% Stress test for code-loading/staging changes: drives many staging
%% generations through load/reload/delete/purge/trace/on_load/fun cycles
%% and checks dispatch correctness after each step.
%% Prints STRESS OK or dies loudly.

-compile(nowarn_deprecated_catch).

main([Dir]) ->
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.beam"))),
    Mods = [begin
                {ok, Bin} = file:read_file(F),
                {list_to_atom(filename:basename(F, ".beam")), Bin}
            end || F <- Files],
    true = length(Mods) >= 20,

    %% 1. Initial load + call checks.
    [load_fresh(M, B) || {M, B} <- Mods],
    [check(M) || {M, _} <- Mods],

    %% 2. Reload everything (creates old code), recheck, purge.
    [begin
         {module, M} = erlang:load_module(M, B),
         check(M)
     end || {M, B} <- Mods],
    [begin true = erlang:purge_module(M) orelse true end || {M, _} <- Mods],
    [check(M) || {M, _} <- Mods],

    %% 3. Delete + purge a subset; calls must hit error_handler (undef),
    %%    then reload and recheck (export entries cycle stub <-> loaded).
    Subset = lists:sublist(Mods, 30),
    [begin
         true = erlang:delete_module(M),
         true = erlang:purge_module(M)
     end || {M, _} <- Subset],
    [begin
         {'EXIT', {undef, _}} = (catch M:f_1(0))
     end || {M, _} <- Subset],
    [begin
         {module, M} = erlang:load_module(M, B),
         check(M)
     end || {M, B} <- Subset],

    %% 4. Tracing on exported functions across reloads (export trampolines
    %%    written on the ACTIVE index by install/uninstall).
    Tracee = spawn_link(fun tracee_loop/0),
    1 = erlang:trace(Tracee, true, [call]),
    [{TM1, TB1}, {TM2, _}] = lists:sublist(Mods, 2),
    1 = erlang:trace_pattern({TM1, f_1, 1}, true, [global]),
    1 = erlang:trace_pattern({TM2, f_2, 1}, true, [global]),
    Tracee ! {call, self(), TM1, f_1, [5]},
    receive {result, R1} -> 6 = R1 end,
    receive {trace, Tracee, call, {TM1, f_1, [5]}} -> ok
    after 2000 -> error(no_trace_msg)
    end,
    %% Reload traced module mid-trace, then untrace.
    {module, TM1} = erlang:load_module(TM1, TB1),
    true = erlang:purge_module(TM1),
    check(TM1),
    erlang:trace_pattern({TM1, '_', '_'}, false, [global]),
    erlang:trace_pattern({TM2, '_', '_'}, false, [global]),
    Tracee ! {call, self(), TM1, f_1, [5]},
    receive {result, R2} -> 6 = R2 end,
    check(TM1), check(TM2),

    %% 5. Funs: compile a module with closures at runtime, hold fun refs
    %%    across reload + purge (fun staging + purge dirty paths).
    FunMod = stress_fun_mod,
    FunBin = compile_fun_mod(FunMod, 1),
    {module, FunMod} = erlang:load_module(FunMod, FunBin),
    F1 = FunMod:make_adder(10),
    15 = F1(5),
    FunBin2 = compile_fun_mod(FunMod, 2),
    {module, FunMod} = erlang:load_module(FunMod, FunBin2),
    F2 = FunMod:make_adder(10),
    15 = F2(5),
    15 = F1(5),                       % old fun still callable (old code)
    true = erlang:purge_module(FunMod),
    {'EXIT', {{badfun, F1}, _}} = (catch F1(5)),  % purged
    15 = F2(5),
    %% Reload thrice more to rotate all 3 code indices with funs in play.
    lists:foreach(
      fun(N) ->
              B = compile_fun_mod(FunMod, N),
              {module, FunMod} = erlang:load_module(FunMod, B),
              true = erlang:purge_module(FunMod),
              G = FunMod:make_adder(N),
              true = (G(1) =:= N + 1)
      end, [3, 4, 5]),

    %% 6. on_load success and failure paths.
    OkMod = stress_onload_ok,
    {module, OkMod} = load_onload_mod(OkMod, true),
    ok = OkMod:ping(),
    FailMod = stress_onload_fail,
    {error, on_load_failure} = load_onload_mod(FailMod, false),
    {'EXIT', {undef, _}} = (catch FailMod:ping()),

    %% 7. Batched atomic load of fresh copies (single staging cycle for
    %%    many modules).
    Prepared = [begin
                    code:purge(M),
                    {M, atom_to_list(M) ++ ".beam", B}
                end || {M, B} <- lists:sublist(Mods, 20)],
    ok = case code:atomic_load(Prepared) of
             ok -> ok;
             {error, _} = E -> error({atomic_load, E})
         end,
    [check(M) || {M, _} <- lists:sublist(Mods, 20)],

    %% 8. Concurrent loading from many processes (disjoint modules) to
    %%    exercise permission queue + upsert insertion outside windows.
    Parent = self(),
    Chunks = chunk4(Mods),
    Pids = [spawn_link(fun() ->
                               [begin
                                    catch erlang:purge_module(M),
                                    {module, M} = erlang:load_module(M, B),
                                    check(M)
                                end || {M, B} <- C],
                               Parent ! {done, self()}
                       end) || C <- Chunks],
    [receive {done, P} -> ok after 60000 -> error(concurrent_timeout) end
     || P <- Pids],
    [catch erlang:purge_module(M) || {M, _} <- Mods],
    [check(M) || {M, _} <- Mods],

    %% 9. Final full recheck.
    io:format("STRESS OK~n"),
    halt(0).

load_fresh(M, B) ->
    {module, M} = erlang:load_module(M, B).

%% Sanity calls against the generated module shape (see gen_modules.escript).
check(M) ->
    2 = M:dispatch(1, 1) div M:dispatch(1, 1) * 2,
    Expected1 = list_to_atom("result_atom_" ++ mod_index(M) ++ "_1"),
    Expected1 = M:f_1(0),
    true = is_tuple(M:data()),
    V = M:f_2([1, 2]),
    true = is_list(V),
    ok.

mod_index(M) ->
    "bench_mod_" ++ Idx = atom_to_list(M),
    integer_to_list(list_to_integer(Idx)).

tracee_loop() ->
    receive
        {call, From, M, F, A} ->
            From ! {result, apply(M, F, A)},
            tracee_loop()
    end.

compile_fun_mod(Name, N) ->
    Src = io_lib:format(
            "-module(~s).~n"
            "-export([make_adder/1, version/0]).~n"
            "version() -> ~b.~n"
            "make_adder(X) -> fun(Y) -> X + Y + (~b - ~b) end.~n",
            [Name, N, N, N]),
    compile_src(Name, Src).

load_onload_mod(Name, Ok) ->
    OnLoadResult = case Ok of true -> "ok"; false -> "fail" end,
    Src = io_lib:format(
            "-module(~s).~n"
            "-export([ping/0]).~n"
            "-on_load(init/0).~n"
            "init() -> ~s.~n"
            "ping() -> ok.~n",
            [Name, OnLoadResult]),
    Bin = compile_src(Name, Src),
    %% on_load requires going through the code server.
    code:load_binary(Name, atom_to_list(Name) ++ ".erl", Bin).

compile_src(Name, Src) ->
    {ok, Tokens, _} = erl_scan:string(lists:flatten(Src)),
    Forms = split_forms(Tokens, [], []),
    Parsed = [begin {ok, F} = erl_parse:parse_form(T), F end || T <- Forms],
    {ok, Name, Bin} = compile:forms(Parsed, []),
    Bin.

split_forms([], [], Acc) -> lists:reverse(Acc);
split_forms([{dot, _} = D | Rest], Cur, Acc) ->
    split_forms(Rest, [], [lists:reverse([D | Cur]) | Acc]);
split_forms([T | Rest], Cur, Acc) ->
    split_forms(Rest, [T | Cur], Acc).

chunk4(L) ->
    N = length(L) div 4,
    {A, R1} = lists:split(N, L),
    {B, R2} = lists:split(N, R1),
    {C, D} = lists:split(N, R2),
    [A, B, C, D].
