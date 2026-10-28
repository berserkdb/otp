#!/usr/bin/env bash
# Runs the benchmarks interleaved across variants, pinned to a fixed core set.
#   run_bench.sh micro|compile|elixir RUNS
set -euo pipefail
B=${B:-$(cd "$(dirname "$0")" && pwd)}
CORES=${CORES:-8-15}
kind=$1; runs=$2
read -ra variants <<< "${VARIANTS:-base name hash hash1}"
nv=${#variants[@]}
mkdir -p $B/results
for run in $(seq 1 "$runs"); do
  # rotate the order so no variant always runs first
  off=$(( (run - 1) % nv ))
  for i in $(seq 0 $(( nv - 1 ))); do
    v=${variants[$(( (i + off) % nv ))]}
    erl=$B/$v/bin/erl
    case $kind in
      micro)
        taskset -c "$CORES" "$erl" -noshell +S 1 -pa $B/ebin \
          -run atom_order_bench main $v $run -s init stop >> $B/results/micro.csv ;;
      compile)
        taskset -c "$CORES" "$erl" -noshell +S 1 -pa $B/ebin \
          -run compile_bench main $v $run $B/base -s init stop >> $B/results/compile.csv ;;
      elixir)
        ex=$B/elixir-$v
        ( cd $ex && make clean >/dev/null 2>&1
          s=$(date +%s.%N)
          PATH=$B/$v/bin:$PATH taskset -c "$CORES" make compile >/dev/null 2>&1
          e=$(date +%s.%N)
          echo "$v,$run,elixir_make_compile,$(echo "($e - $s) * 1000" | bc | cut -d. -f1)" ) >> $B/results/elixir.csv ;;
    esac
  done
done
