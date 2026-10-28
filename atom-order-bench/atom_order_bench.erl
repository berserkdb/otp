%% Microbenchmarks for map/atom paths affected by ordering and hashing atom
%% keys by name instead of by atom table index.
%%
%%   erl -noshell -pa . -run atom_order_bench main <variant> <run> -s init stop
%%
%% Prints one line per benchmark: variant,run,set,bench,ns_per_op
-module(atom_order_bench).
-export([main/1, order/1]).

-define(TARGET_NS, 30000000).
-define(ROUNDS, 7).

main([Variant, Run]) ->
    rand:seed(exsss, {17, 42, 4711}),
    Sets = atom_sets(),
    [begin
         [report(Variant, Run, SetName, Name, measure(Fun))
          || {Name, Fun} <- benches(Atoms)]
     end || {SetName, Atoms} <- Sets],
    [report(Variant, Run, fields, Name, measure(Fun))
     || {Name, Fun} <- record_benches()],
    ok.

report(Variant, Run, Set, Name, Ns) ->
    io:format("~s,~s,~s,~s,~.3f~n", [Variant, Run, Set, Name, Ns]).

%% Prints the key order of a map built from the given atoms, after creating
%% the atoms in the order given. Used to check order independence.
order([Order]) ->
    Names = ["zeta", "alpha", "mid", "beta", "omega", "gamma", "delta", "eps"],
    Created = case Order of
                  "fwd" -> [list_to_atom(N) || N <- Names];
                  "rev" -> [list_to_atom(N) || N <- lists:reverse(Names)]
              end,
    Small = maps:from_list([{A, 1} || A <- Created]),
    BigNames = [N ++ integer_to_list(I) || N <- Names, I <- lists:seq(1, 8)],
    _ = case Order of
            "fwd" -> [list_to_atom(N) || N <- BigNames];
            "rev" -> [list_to_atom(N) || N <- lists:reverse(BigNames)]
        end,
    Big = maps:from_list([{list_to_atom(N), 1} || N <- BigNames]),
    io:format("~s small ~w~n", [Order, maps:keys(Small)]),
    io:format("~s big   ~w~n", [Order, erlang:phash2(maps:keys(Big))]).

%% --- atom sets ---------------------------------------------------------------

atom_sets() ->
    [{short, [list_to_atom("k" ++ integer_to_list(I)) || I <- lists:seq(1, 1000)]},
     {fields, fields() ++ [list_to_atom("field_" ++ integer_to_list(I))
                           || I <- lists:seq(1, 1000 - length(fields()))]},
     {alias, aliases()},
     {jose, [list_to_atom("atom-" ++ integer_to_list(I)) || I <- lists:seq(1, 1000)]}].

fields() ->
    [id, name, email, status, inserted_at, updated_at, user_id, account_id,
     type, value, metadata, tags, count, total, price, currency, description,
     title, body, url, path, method, headers, params, query, host, port,
     scheme, timeout, retries, owner, version].

aliases() ->
    Ctx = ["Accounts", "Billing", "Catalog", "Orders", "Shipping", "Inventory",
           "Notifications", "Search", "Reporting", "Auth", "Admin", "Payments",
           "Analytics", "Storage", "Workers", "Web", "Api", "Repo", "Telemetry",
           "Integrations"],
    Names = ["User", "Invoice", "Product", "Order", "Shipment", "Item", "Email",
             "Index", "Report", "Token", "Role", "Charge", "Event", "Bucket",
             "Job", "Controller", "View", "Schema", "Metric", "Client",
             "Session", "Policy", "Query", "Cache", "Supervisor", "Server",
             "Registry", "Handler", "Plug", "Router", "Socket", "Channel",
             "Presence", "Endpoint", "Changeset", "Context", "Resolver",
             "Serializer", "Adapter", "Config", "Migration", "Seed", "Factory",
             "Fixture", "Helper", "Mailer", "Notifier", "Scheduler", "Stream",
             "Store"],
    [list_to_atom("Elixir.MyApp." ++ C ++ "." ++ N) || N <- Names, C <- Ctx].

%% --- benchmarks --------------------------------------------------------------

benches(Atoms) ->
    K8 = lists:sublist(Atoms, 8),
    K32 = lists:sublist(Atoms, 32),
    K1000 = Atoms,
    S8 = shuffle(K8), S32 = shuffle(K32), S1000 = shuffle(K1000),
    KV8 = [{K, 1} || K <- S8],
    KV32 = [{K, 1} || K <- S32],
    KV1000 = [{K, 1} || K <- S1000],
    M32 = maps:from_list(KV32),
    M1000 = maps:from_list(KV1000),
    MA = maps:from_list([{K, 1} || K <- lists:sublist(K32, 1, 16)]),
    MB = maps:from_list([{K, 2} || K <- lists:sublist(K32, 9, 16)]),
    SameKeys = [maps:from_list([{K, rand:uniform(4)} || K <- K8])
                || _ <- lists:seq(1, 1000)],
    DiffKeys = [maps:from_list([{K, 1} || K <- lists:sublist(shuffle(K32), 8)])
                || _ <- lists:seq(1, 1000)],
    Bin32 = term_to_binary(M32),
    ok = persistent_term_setup(K32),
    [{from_list_8,   fun(N) -> loop_from_list(N, KV8) end},
     {from_list_32,  fun(N) -> loop_from_list(N, KV32) end},
     {from_list_1000, fun(N) -> loop_from_list(N, KV1000) end},
     {put_new_32,    fun(N) -> loop_put_new(N, S32) end},
     {match_dyn_32,  fun(N) -> loop_match(N, S32, M32) end},
     {match_dyn_1000, fun(N) -> loop_match(N, S1000, M1000) end},
     {maps_get_32,   fun(N) -> loop_maps_get(N, S32, M32) end},
     {maps_get_1000, fun(N) -> loop_maps_get(N, S1000, M1000) end},
     {merge_16_16,   fun(N) -> loop_merge(N, MA, MB) end},
     {sort_same_keys, fun(N) -> loop_sort(N, SameKeys) end},
     {sort_diff_keys, fun(N) -> loop_sort(N, DiffKeys) end},
     {t2b_32,        fun(N) -> loop_t2b(N, M32) end},
     {b2t_32,        fun(N) -> loop_b2t(N, Bin32) end},
     {pdict_get_32,  fun(N) -> loop_pdict(N, S32) end},
     {pterm_get_32,  fun(N) -> loop_pterm(N, S32) end},
     {ets_lookup_32, fun(N) -> loop_ets(N, S32) end}].

%% Updates with literal keys, as record-style code does.
record_benches() ->
    M = maps:from_list([{K, 0} || K <- fields()]),
    [{update_literal_3,  fun(N) -> loop_update3(N, M) end},
     {match_literal_3,   fun(N) -> loop_match3(N, M) end},
     {build_literal_8,   fun(N) -> loop_build8(N) end}].

%% Each loop runs N iterations; the measured unit is one iteration.

loop_from_list(0, _) -> ok;
loop_from_list(N, KV) -> _ = maps:from_list(KV), loop_from_list(N - 1, KV).

loop_put_new(0, _) -> ok;
loop_put_new(N, Ks) -> _ = put_all(Ks, #{}), loop_put_new(N - 1, Ks).

put_all([K | Ks], M) -> put_all(Ks, M#{K => 1});
put_all([], M) -> M.

loop_match(0, _, _) -> ok;
loop_match(N, Ks, M) -> _ = match_all(Ks, M, 0), loop_match(N - 1, Ks, M).

match_all([K | Ks], M, Acc) ->
    #{K := V} = M,
    match_all(Ks, M, Acc + V);
match_all([], _, Acc) -> Acc.

loop_maps_get(0, _, _) -> ok;
loop_maps_get(N, Ks, M) -> _ = get_all(Ks, M, 0), loop_maps_get(N - 1, Ks, M).

get_all([K | Ks], M, Acc) -> get_all(Ks, M, Acc + maps:get(K, M));
get_all([], _, Acc) -> Acc.

loop_merge(0, _, _) -> ok;
loop_merge(N, A, B) -> _ = maps:merge(A, B), loop_merge(N - 1, A, B).

loop_sort(0, _) -> ok;
loop_sort(N, L) -> _ = lists:sort(L), loop_sort(N - 1, L).

loop_t2b(0, _) -> ok;
loop_t2b(N, M) -> _ = term_to_binary(M), loop_t2b(N - 1, M).

loop_b2t(0, _) -> ok;
loop_b2t(N, B) -> _ = binary_to_term(B), loop_b2t(N - 1, B).

loop_pdict(N, Ks) ->
    [put(K, 1) || K <- Ks],
    loop_pdict_1(N, Ks).

loop_pdict_1(0, _) -> ok;
loop_pdict_1(N, Ks) -> _ = pdict_all(Ks, 0), loop_pdict_1(N - 1, Ks).

pdict_all([K | Ks], Acc) -> pdict_all(Ks, Acc + get(K));
pdict_all([], Acc) -> Acc.

persistent_term_setup(Ks) ->
    [persistent_term:put({?MODULE, K}, 1) || K <- Ks],
    [persistent_term:put(K, 1) || K <- Ks],
    ok.

loop_pterm(0, _) -> ok;
loop_pterm(N, Ks) -> _ = pterm_all(Ks, 0), loop_pterm(N - 1, Ks).

pterm_all([K | Ks], Acc) -> pterm_all(Ks, Acc + persistent_term:get(K));
pterm_all([], Acc) -> Acc.

loop_ets(N, Ks) ->
    T = ets:new(t, [set]),
    ets:insert(T, [{K, 1} || K <- Ks]),
    loop_ets_1(N, Ks, T),
    ets:delete(T),
    ok.

loop_ets_1(0, _, _) -> ok;
loop_ets_1(N, Ks, T) -> _ = ets_all(Ks, T, 0), loop_ets_1(N - 1, Ks, T).

ets_all([K | Ks], T, Acc) -> [{_, V}] = ets:lookup(T, K), ets_all(Ks, T, Acc + V);
ets_all([], _, Acc) -> Acc.

loop_update3(0, M) -> M;
loop_update3(N, M) ->
    loop_update3(N - 1, M#{status := N, updated_at := N, version := N}).

loop_match3(0, _) -> ok;
loop_match3(N, M) ->
    #{id := _, status := _, version := _} = M,
    loop_match3(N - 1, M).

loop_build8(0) -> ok;
loop_build8(N) ->
    _ = #{id => N, name => N, email => N, status => N,
          inserted_at => N, updated_at => N, user_id => N, type => N},
    loop_build8(N - 1).

%% --- measurement -------------------------------------------------------------

%% Calibrates an iteration count that takes about TARGET_NS, then returns the
%% median ns per iteration over ROUNDS rounds.
measure(Fun) ->
    N = calibrate(Fun, 1),
    Times = [time_ns(Fun, N) / N || _ <- lists:seq(1, ?ROUNDS)],
    lists:nth((?ROUNDS + 1) div 2, lists:sort(Times)).

calibrate(Fun, N) ->
    case time_ns(Fun, N) of
        T when T >= ?TARGET_NS div 4 -> max(1, (N * ?TARGET_NS) div max(1, T));
        _ -> calibrate(Fun, N * 2)
    end.

time_ns(Fun, N) ->
    erlang:garbage_collect(),
    T0 = erlang:monotonic_time(nanosecond),
    Fun(N),
    erlang:monotonic_time(nanosecond) - T0.

shuffle(L) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- L])].
