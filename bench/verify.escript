#!/usr/bin/env escript
%% Correctness check for loader patches: load every bench module, execute a
%% spread of its functions (literals, atoms, pattern matching, local/remote
%% calls), and print a hash of all results. The hash must be identical
%% before and after any loader change.
%% Usage: verify.escript <ebindir>

-compile(nowarn_deprecated_catch).

main([Dir]) ->
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.beam"))),
    Results =
        [begin
             {ok, Bin} = file:read_file(F),
             Mod = list_to_atom(filename:basename(F, ".beam")),
             {module, Mod} = erlang:load_module(Mod, Bin),
             exercise(Mod)
         end || F <- Files],
    io:format("OK ~b~n", [erlang:phash2(Results, 1 bsl 32)]),
    halt(0).

exercise(Mod) ->
    Data = Mod:data(),
    MD5 = Mod:module_info(md5),
    Funs = [begin
                K = I,
                [Mod:dispatch(K, 0),
                 Mod:dispatch(K, 5),
                 Mod:dispatch(K, [1, 2, 3]),
                 Mod:dispatch(K, {pair, 1, 2}),
                 Mod:dispatch(K, #{}),
                 Mod:dispatch(K, <<1, 2, 3>>),
                 Mod:dispatch(K, make_ref_safe())]
            end || I <- lists:seq(1, 25)],
    GFuns = [[catch Mod:g_1([1, 2, 3], I),
              catch Mod:g_2(#{}, I),
              catch Mod:g_3(<<1, 2, 3>>, I),
              catch Mod:g_4({a, b}, I),
              catch Mod:g_5(self_safe(), I)] || I <- [0, 1, 42]],
    Exports = lists:sort(Mod:module_info(exports)),
    {Data, MD5, Funs, GFuns, Exports}.

%% Deterministic stand-ins (refs/pids vary between runs).
make_ref_safe() -> not_a_ref.
self_safe() -> not_a_pid.
