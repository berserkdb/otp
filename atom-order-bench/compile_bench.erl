%% Compiles the Erlang sources of kernel, stdlib and compiler in memory, one
%% file at a time, and prints the total wall time in milliseconds.
%%
%%   erl -noshell -pa . -run compile_bench main <variant> <run> <src_root> -s init stop
-module(compile_bench).
-export([main/1]).

main([Variant, Run, Root]) ->
    Apps = ["kernel", "stdlib", "compiler"],
    Files = lists:append([lists:sort(filelib:wildcard(filename:join([Root, "lib", A, "src", "*.erl"])))
                          || A <- Apps]),
    Incs = [{i, filename:join([Root, "lib", A, D])} || A <- Apps, D <- ["include", "src"]],
    Opts = [binary, return_errors, deterministic, {i, filename:join(Root, "lib")} | Incs],
    T0 = erlang:monotonic_time(millisecond),
    Ok = length([F || F <- Files, element(1, compile:file(F, Opts)) =:= ok]),
    T = erlang:monotonic_time(millisecond) - T0,
    io:format("~s,~s,erlc_kernel_stdlib_compiler,~b,~b/~b~n",
              [Variant, Run, T, Ok, length(Files)]).
