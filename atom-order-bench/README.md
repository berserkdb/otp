# Map order independent of atom creation order: benchmarks

Benchmarks for the prototype on this branch, which makes the order of
atom-keyed maps a function of the keys alone instead of the order the atoms
were created in. Discussion:
https://erlangforums.com/t/proposal-an-opt-in-emulator-flag-that-makes-map-order-independent-of-atom-creation-order/6033

This directory is not meant for merging. It is here so the numbers can be
reproduced.

## Variants

All four are built from the same commit (`1e86608b765`) and differ only in
erts. None of them uses a flag.

| Variant | Flatmap order of atom keys | Internal hash of an atom |
|---|---|---|
| `base` | atom table index (stock OTP) | atom table index |
| `name` | name (term order) | name hash, read through the atom table |
| `hash` | name hash, ties by name, read through the atom table | name hash, read through the atom table |
| `hash1` | name hash, ties by name, read from a flat array | name hash, read from a flat array |

`hash1` is the commit on this branch. `patch_variant.py` applies any of the
three to a checkout of the base commit (x86-64 JIT only; the commit on this
branch also makes the ARM JIT defer to the C implementation).

The internal hash is used by hashmaps (more than 32 keys), `persistent_term`
and `enif_hash`. ETS and the process dictionary have their own index-based
hashes for atoms and are unchanged, so they serve as controls.

## Correctness

* `map_SUITE` passes (64 of 64) on all four variants.
* `atom_order_bench:order/1` creates the same atoms in opposite orders in two
  nodes. In `base` the key order of small and large maps differs between the
  two; in `name`, `hash` and `hash1` it is identical.

## Method

* AMD EPYC 7502P, Ubuntu 24.04, GCC 13.3, default `./configure` without wx,
  Java, ODBC and the wx-based applications.
* Runs pinned to cores 8 to 15 with `taskset`; microbenchmarks with `+S 1`.
* Variants are interleaved and their order rotated each run. Ratios are
  computed per run against `base` from the same run, then the median is
  taken; brackets give the min and max ratio over the runs.
* Microbenchmarks: 7 runs; each benchmark calibrates to about 30 ms and
  reports the median of 7 rounds.
* `erlc`: compiles every `.erl` in kernel, stdlib and compiler in memory, one
  file at a time, in one node (`compile_bench.erl`), 5 runs.
* Elixir: `make clean && make compile` of Elixir 1.20.4, 3 runs.

Atom sets used by the microbenchmarks:

* `short`: `k1`, `k2`, ...
* `fields`: record-style field names (`id`, `name`, `status`, ...)
* `alias`: Elixir module names such as `'Elixir.MyApp.Accounts.User'`,
  which share a long prefix (worst case for name comparison)
* `jose`: `'atom-1'`, `'atom-2'`, ..., as in the benchmark in #6151

## Results

Whole compiles (median wall time and change against `base`):

| Workload | base | name | hash | hash1 |
|---|---|---|---|---|
| erlc kernel, stdlib, compiler | 90.5 s | +0.3% | +1.6% | +0.2% |
| Elixir `make compile` | 60.1 s | +0.9% | 0.0% | +0.9% |

Selected microbenchmarks (change against `base`, range over the four atom
sets):

| Operation | name | hash1 |
|---|---|---|
| `maps:from_list`, 8 atom keys | +20 to +161% | +16 to +48% |
| `maps:from_list`, 32 atom keys | +64 to +527% | +33 to +68% |
| `maps:merge`, 16 + 16 keys | +40 to +272% | +3 to +24% |
| dynamic-key match, 1000-key map | +43 to +49% | +21 to +26% |
| `maps:get`, 1000-key map | +34 to +37% | +13 to +17% |
| `persistent_term:get` | +50 to +70% | +3 to +19% |
| sort maps with differing keys | -68 to -78% | +4 to +9% |
| `binary_to_term`, 32 keys | -10 to +6% | -9 to -14% |
| ETS, process dictionary, `term_to_binary` (controls) | about 0% | about 0% |

The full table is in `results/summary.txt` and the raw data in
`results/*.csv` (`results/round1/` is an earlier run of `base`, `name` and
`hash` that the second run reproduces).

## Caveats

* x86-64 only. No ARM64 numbers; the ARM JIT in the commit calls the C
  implementation and has not been built or tested in this form.
* `name` and `hash` share the same `persistent_term` code but consistently
  differ by about 30%, which is most likely code layout. Treat differences
  below about 20% in a single operation with care.
* The stored name hash (hashpjw) has 28 bits, so in nodes with many atoms
  some pairs collide. Ordering stays correct through the tie-break, and
  hashmaps handle collisions, but colliding keys in one map cost more.
* `hash1` allocates one `Uint32` per possible atom (4 MB with the default
  limit). Only pages for atoms that exist are touched, but the allocation is
  reported in full.

## Reproducing

```sh
# from an OTP checkout at 1e86608b765, one worktree per variant
for v in base name hash hash1; do git worktree add --detach $B/$v 1e86608b765; done
for v in name hash hash1; do python3 patch_variant.py $B/$v $v; done
# build each: ./configure --without-wx ... && make -j
mkdir -p $B/ebin && $B/base/bin/erlc -o $B/ebin atom_order_bench.erl compile_bench.erl
B=$B ./run_bench.sh micro 7
B=$B ./run_bench.sh compile 5
B=$B ./run_bench.sh elixir 3   # needs Elixir checkouts at $B/elixir-<variant>
python3 analyze.py $B/results/micro.csv
```
