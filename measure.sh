#!/usr/bin/env bash
# measure.sh — run ALL measurements once, before recording. Takes ~4 min.
# Every output goes to results/; results/summary.md = the before/after table.
# Usage:  bash measure.sh
set -u
export PERF_PAGER=cat
export LC_ALL=C          # plain numbers: 48145467334, 2.66 (no locale separators)
FG=~/FlameGraph
E="power/energy-pkg/,power/energy-cores/,power/energy-ram/"
mkdir -p results

echo "== build"
make all asm > /dev/null
make vecreport 2> results/vecreport.txt

echo "== 1. perf record + FlameGraph (O0 ~25 s, O3 ~3 s)"
for v in O0 O3; do
  perf record -F 499 --call-graph dwarf -o perf_$v.data ./lab_$v > results/run_$v.txt 2> /dev/null
  perf script -i perf_$v.data 2> /dev/null > out_$v.perf
  $FG/stackcollapse-perf.pl out_$v.perf > out_$v.folded
  $FG/flamegraph.pl --title "lab_$v" out_$v.folded > results/flame_$v.svg
done
sed 's/^[^;]*;//' out_O0.folded > a.folded
sed 's/^[^;]*;//' out_O3.folded > b.folded
$FG/difffolded.pl -n a.folded b.folded | $FG/flamegraph.pl --title "O0 -> O3" > results/flame_diff.svg

echo "== 2. time, perf stat, perf report (~1 min)"
for v in O0 O3; do
  /usr/bin/time --verbose -o results/time_$v.txt ./lab_$v > /dev/null
  perf stat -d -o results/stat_$v.txt ./lab_$v > /dev/null
  perf report -i perf_$v.data --stdio --no-children -g none > results/report_$v.txt 2> /dev/null
  perf report -i perf_$v.data --stdio --no-children -g none --sort dso > results/dso_$v.txt 2> /dev/null
done
perf annotate -i perf_O0.data --stdio -M intel branchy_sum > results/annotate_branchy_O0.txt 2> /dev/null

echo "== 3. energy: idle 10 s, then O0, then O3 (don't touch the laptop)"
sleep 3
perf stat -a -e $E -o results/energy_idle.txt sleep 10
perf stat -a -e $E -o results/energy_O0.txt ./lab_O0 > /dev/null
perf stat -a -e $E -o results/energy_O3.txt ./lab_O3 > /dev/null

echo "== summary"
num()  { tr -d ' ,' <<< "$1"; }                                   # "48,145,467" -> 48145467
tv()   { grep -m1 "$2" results/time_$1.txt | awk -F': ' '{print $2}'; }
st()   { num "$(grep -m1 " $2 " results/stat_$1.txt | awk '{print $1}')"; }
ipc()  { grep -m1 'insn per cycle' results/stat_$1.txt | awk '{for(i=1;i<=NF;i++) if($i=="#") print $(i+1)}'; }
bmp()  { grep -m1 'branch-misses' results/stat_$1.txt | awk '{for(i=1;i<=NF;i++) if($i=="#") print $(i+1)}'; }
j()    { num "$(grep -m1 "$2" results/energy_$1.txt | awk '{print $1}')"; }
sec()  { grep -m1 'seconds time elapsed' results/energy_$1.txt | awk '{print $1}'; }
tot()  { grep -m1 'total' results/run_$1.txt | awk '{print $3}'; }
calc() { awk "BEGIN{v=$1; printf \"%.2f\", v}" 2> /dev/null || echo "-"; }
val()  { [[ "$1" =~ ^[0-9.]+%?$ ]] && echo "$1" || echo "-"; }   # "<not supported>" -> "-"

Pi=$(calc "($(j idle energy-pkg)+$(j idle energy-ram))/10")
for v in O0 O3; do
  eval "Es_$v=$(calc "$(j $v energy-pkg)+$(j $v energy-ram)")"
  eval "Ep_$v=$(calc "$(j $v energy-pkg)+$(j $v energy-ram)-$Pi*$(sec $v)")"
done
row() { local a b; a=$(val "$2"); b=$(val "$3")
        printf '| %-26s | %14s | %14s | %8s |\n' "$1" "$a" "$b" "$(calc "${a%\%}/${b%\%}")"; }
{
  echo "# Results (lab_O0 vs lab_O3)"
  echo
  printf '| %-26s | %14s | %14s | %8s |\n' "Metric" "lab_O0" "lab_O3" "O0/O3"
  printf '|%s|%s|%s|%s|\n' "----------------------------" "----------------" "----------------" "----------"
  row "[total] from program, s"   "$(tot O0)" "$(tot O3)"
  printf '| %-26s | %14s | %14s | %8s |\n' "Elapsed (time -v)" "$(tv O0 Elapsed)" "$(tv O3 Elapsed)" ""
  row "User time, s"              "$(tv O0 'User time')" "$(tv O3 'User time')"
  row "Max resident set, KB"      "$(tv O0 'Maximum resident')" "$(tv O3 'Maximum resident')"
  row "cycles"                    "$(st O0 cycles)" "$(st O3 cycles)"
  row "instructions"              "$(st O0 instructions)" "$(st O3 instructions)"
  row "IPC (insn per cycle)"      "$(ipc O0)" "$(ipc O3)"
  row "branch-misses, %"          "$(bmp O0 | tr -d %)" "$(bmp O3 | tr -d %)"
  row "L1-dcache-loads"           "$(st O0 L1-dcache-loads)" "$(st O3 L1-dcache-loads)"
  row "E_pkg, J"                  "$(j O0 energy-pkg)" "$(j O3 energy-pkg)"
  row "E_cores, J"                "$(j O0 energy-cores)" "$(j O3 energy-cores)"
  row "E_ram, J"                  "$(j O0 energy-ram)" "$(j O3 energy-ram)"
  row "E_sys = pkg + ram, J"      "$Es_O0" "$Es_O3"
  row "E_prog = E_sys - P_idle*t, J" "$Ep_O0" "$Ep_O3"
  echo
  echo "Idle 10 s: E_pkg = $(j idle energy-pkg) J, E_ram = $(j idle energy-ram) J, P_idle = $Pi W"
} > results/summary.md
cat results/summary.md
echo "Done. All files are in results/"
