#!/usr/bin/env bash
# measure.sh — runs every measurement of the lab and writes the report.
#   results/   all raw outputs (time, perf stat, perf report, energy, asm, FlameGraphs)
#   README.md  the lab report with every output embedded (what GitHub shows first)
# Usage:  bash measure.sh        (~6 min; close OBS/browser, don't touch the laptop)
set -u
export PERF_PAGER=cat
export LC_ALL=C          # plain numbers: 48145467334, 2.66 (no locale separators)
FG=~/FlameGraph
E="power/energy-pkg/,power/energy-cores/,power/energy-ram/"
R=3                      # repeats for energy (perf stat prints mean and +- spread)
mkdir -p results
# perf needs this after every reboot (asks for the sudo password once)
[ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le -1 ] || sudo sysctl -qw kernel.perf_event_paranoid=-1

echo "== build"
make -B all asm > /dev/null       # -B: always rebuild from lab.cpp
make vecreport > /dev/null 2> results/vecreport.txt

echo "== 1. perf record + FlameGraph"
for v in O0 O3; do
  perf record -F 499 --call-graph dwarf -o perf_$v.data ./lab_$v > results/run_$v.txt 2> /dev/null
  perf script -i perf_$v.data 2> /dev/null > out_$v.perf
  $FG/stackcollapse-perf.pl out_$v.perf > out_$v.folded
  $FG/flamegraph.pl --title "lab_$v" out_$v.folded > results/flame_$v.svg
done
sed 's/^[^;]*;//' out_O0.folded > a.folded
sed 's/^[^;]*;//' out_O3.folded > b.folded
$FG/difffolded.pl -n a.folded b.folded | $FG/flamegraph.pl --title "O0 -> O3" > results/flame_diff.svg

echo "== 2. time, perf stat, perf report"
for v in O0 O3; do
  /usr/bin/time --verbose -o results/time_$v.txt ./lab_$v > /dev/null
  perf stat -d -o results/stat_$v.txt ./lab_$v > /dev/null
  perf report -i perf_$v.data --stdio --no-children -g none > results/report_$v.txt 2> /dev/null
  perf report -i perf_$v.data --stdio --no-children -g none --sort dso > results/dso_$v.txt 2> /dev/null
  head -30 results/report_$v.txt > results/report_top_$v.txt
done
perf annotate -i perf_O0.data --stdio -M intel branchy_sum > results/annotate_branchy_O0.txt 2> /dev/null

echo "== 3. energy: idle 10 s x$R, then O0 x$R, then O3 x$R (don't touch the laptop)"
sleep 3
perf stat -a -r $R -e $E -o results/energy_idle.txt sleep 10
perf stat -a -r $R -e $E -o results/energy_O0.txt ./lab_O0 > /dev/null
perf stat -a -r $R -e $E -o results/energy_O3.txt ./lab_O3 > /dev/null

echo "== 4. assembly excerpts"
fn() { awk -v f="<$2>:" '$0 ~ /^[0-9a-f]+ <.*>:$/ {on = ($2 == f)} on' asm/$1.objdump.txt; }
fn lab_O0 matmul      | grep -E 'movss|mulss|addss'               | head -8  > results/asm_matmul_O0.txt
fn lab_O3 matmul      | grep -E 'vbroadcastss|vfmadd|vmovups'     | head -8  > results/asm_matmul_O3.txt
fn lab_O0 branchy_sum | grep -E '\b(cmp|jle|jg|jl|jge|add)\b'      | head -8  > results/asm_branchy_O0.txt
fn lab_O3 branchy_sum | grep -E 'vpcmpgtd|vpand|vpaddq|vpmovsxdq' | head -8  > results/asm_branchy_O3.txt
grep -E 'vectorized' results/vecreport.txt > results/vecreport_short.txt

echo "== summary + README.md"
num()  { tr -d ' ,' <<< "$1"; }
tv()   { grep -m1 "$2" results/time_$1.txt | awk -F': ' '{print $2}'; }
st()   { num "$(grep -m1 " $2 " results/stat_$1.txt | awk '{print $1}')"; }
hash_() { grep -m1 "$2" results/stat_$1.txt | awk '{for(i=1;i<=NF;i++) if($i=="#") print $(i+1)}' | tr -d %; }
j()    { num "$(grep -m1 "$2" results/energy_$1.txt | awk '{print $1}')"; }
sec()  { grep -m1 'seconds time elapsed' results/energy_$1.txt | awk '{print $1}'; }
part() { grep -m1 "\[$2" results/run_$1.txt | awk '{print $(NF-1)}'; }
pct()  { awk -v f="[.] $2" 'index($0, f) {gsub("%", "", $1); s += $1; n++} END {if (n) printf "%.2f%%", s}' results/report_$1.txt; }
calc() { awk "BEGIN{v=$1; printf \"%.2f\", v}" 2> /dev/null || echo "-"; }
val()  { [[ "$1" =~ ^[0-9.]+%?$ ]] && echo "$1" || echo "-"; }    # "<not supported>" -> "-"
ratio(){ local a b; a=$(val "$1"); b=$(val "$2"); calc "${a%\%}/${b%\%}"; }
row()  { printf '| %s | %s | %s | %s |\n' "$1" "$(val "$2")" "$(val "$3")" "$(ratio "$2" "$3")"; }

# energy numbers
Pi=$(calc "($(j idle energy-pkg)+$(j idle energy-ram))/$(sec idle)")
for v in O0 O3; do
  t=$(sec $v)
  eval "T_$v=$t"
  eval "Es_$v=$(calc "$(j $v energy-pkg)+$(j $v energy-ram)")"
  eval "Ep_$v=$(calc "$(j $v energy-pkg)+$(j $v energy-ram)-$Pi*$t")"
  eval "P_$v=$(calc "($(j $v energy-pkg)+$(j $v energy-ram))/$t")"
done

{
  echo "| Метрика | lab_O0 | lab_O3 | O0/O3 |"
  echo "|---|---:|---:|---:|"
  row "[total] з програми, с"     "$(part O0 total)" "$(part O3 total)"
  row "User time, с"              "$(tv O0 'User time')" "$(tv O3 'User time')"
  row "Max resident set, KB"      "$(tv O0 'Maximum resident')" "$(tv O3 'Maximum resident')"
  row "cycles"                    "$(st O0 cycles)" "$(st O3 cycles)"
  row "instructions"              "$(st O0 instructions)" "$(st O3 instructions)"
  row "IPC (insn per cycle)"      "$(hash_ O0 'insn per cycle')" "$(hash_ O3 'insn per cycle')"
  row "branch-misses, %"          "$(hash_ O0 'branch-misses')" "$(hash_ O3 'branch-misses')"
  row "L1-dcache-loads"           "$(st O0 L1-dcache-loads)" "$(st O3 L1-dcache-loads)"
  row "L1-dcache-load-misses, %"  "$(hash_ O0 'L1-dcache-load-misses')" "$(hash_ O3 'L1-dcache-load-misses')"
} > results/table_metrics.md

{
  echo "| Функція | O0, с | O3, с | Прискорення O0/O3 | Частка в perf report O0 | Частка в perf report O3 |"
  echo "|---|---:|---:|---:|---:|---:|"
  for f in init matmul saxpy branch fib; do
    case $f in branch) sym=branchy_sum ;; init) sym=fill_random ;; *) sym=$f ;; esac
    printf '| %s | %s | %s | %s× | %s | %s |\n' "${sym/fill_random/init (fill_random_f, _i)}" "$(val "$(part O0 $f)")" "$(val "$(part O3 $f)")" \
      "$(ratio "$(part O0 $f)" "$(part O3 $f)")" "$(val "$(pct O0 $sym)")" "$(val "$(pct O3 $sym)")"
  done
} > results/table_functions.md

{
  echo "| Величина | lab_O0 | lab_O3 | O0/O3 |"
  echo "|---|---:|---:|---:|"
  row "t (середнє з $R), с"         "$T_O0" "$T_O3"
  row "E_pkg, Дж"                   "$(j O0 energy-pkg)"   "$(j O3 energy-pkg)"
  row "E_cores, Дж"                 "$(j O0 energy-cores)" "$(j O3 energy-cores)"
  row "E_ram, Дж"                   "$(j O0 energy-ram)"   "$(j O3 energy-ram)"
  row "E_sys = E_pkg + E_ram, Дж"   "$Es_O0" "$Es_O3"
  row "P_avg = E_sys / t, Вт"       "$P_O0"  "$P_O3"
  row "E_prog = E_sys − P_idle·t, Дж" "$Ep_O0" "$Ep_O3"
} > results/table_energy.md

cat results/table_metrics.md results/table_functions.md results/table_energy.md > results/summary.md
echo "" >> results/summary.md
echo "P_idle = $Pi W" >> results/summary.md

# values for the README text
export DATE="$(date '+%Y-%m-%d %H:%M')"
export CPU="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
export SIMD="$(grep -o -w -E 'avx512f|avx2|fma|avx|sse4_2' /proc/cpuinfo | sort -u | tr '\n' ' ')"
export KERNEL="$(uname -r)" GXX="$(g++ --version | head -1)" PERFV="$(perf --version)"
export R Pi
export E_IDLE_PKG="$(j idle energy-pkg)" E_IDLE_RAM="$(j idle energy-ram)" T_IDLE="$(sec idle)"
export T_O0 T_O3 Es_O0 Es_O3 Ep_O0 Ep_O3 P_O0 P_O3
export E_PKG_O0="$(j O0 energy-pkg)" E_RAM_O0="$(j O0 energy-ram)"
export E_PKG_O3="$(j O3 energy-pkg)" E_RAM_O3="$(j O3 energy-ram)"
export SPEED="$(ratio "$(part O0 total)" "$(part O3 total)")"
export ESAVE="$(ratio "$Es_O0" "$Es_O3")" EPSAVE="$(ratio "$Ep_O0" "$Ep_O3")"
export INSN_R="$(ratio "$(st O0 instructions)" "$(st O3 instructions)")"
export TOT_O0="$(part O0 total)" TOT_O3="$(part O3 total)"
export CYC_O0="$(st O0 cycles)" ELAPSED_O0="$(tv O0 Elapsed)"
export FREQ_O0="$(calc "$(st O0 cycles)/$(part O0 total)/1e9")"
export DSO_O0="$(awk '$NF=="lab_O0"{print $1; exit}' results/dso_O0.txt)"
for v in O0 O3; do for s in matmul saxpy branchy_sum fib; do export PCT_${v}_$s="$(pct $v $s)"; done; done

sed -n '/^#==README==/,/^README_TEMPLATE$/p' "$0" | sed '1d;$d' | perl -pe '
  s{\@\@FILE:([^@]+)\@\@}{ my $p = $1; my $c = "(файл $p не знайдено)";
    if (open(my $f, "<", $p)) { local $/; $c = <$f> // ""; chomp $c; } $c }ge;
  s{\@\@(\w+)\@\@}{ (defined $ENV{$1} && $ENV{$1} ne "") ? $ENV{$1} : "-" }ge;
' > README.md

cat results/summary.md
echo "Done: results/ + README.md"
exit 0

: <<'README_TEMPLATE'
#==README==
# Лабораторна робота: профілювання та оптимізація програми

Слобожанін Нікіта, ТК-32. Заміри зроблено @@DATE@@ скриптом `measure.sh`.

## Середовище

| Параметр | Значення |
|---|---|
| CPU | @@CPU@@ |
| SIMD-розширення CPU | @@SIMD@@ |
| Ядро Linux | @@KERNEL@@ |
| Компілятор | @@GXX@@ |
| perf | @@PERFV@@ |

## Програма `lab.cpp`

| Функція | Що робить | Що показує |
|---|---|---|
| `matmul` | множення матриць 1024×1024, порядок i-k-j | обчислювальне навантаження, при -O3 векторизується (AVX2 + FMA) |
| `saxpy` | `y = a·x + y` на векторах по 16 МіБ | навантаження на пам'ять, SIMD допомагає менше |
| `branchy_sum` | сума елементів `≥ 128` випадкового масиву | непередбачуваний `if`, при -O3 замінюється маскою SIMD |
| `fib` | рекурсивне число Фібоначчі, k = 40 | глибокий стек викликів («вежа» на FlameGraph) |

Функції оголошені як `extern "C" __attribute__((noipa))`, щоб імена в perf/FlameGraph були простими і компілятор не вбудовував їх у `main`. Результати сумуються в `checksum`, тому компілятор не може викинути обчислення.

Збірка (`Makefile`):

| Бінарник | Флаги |
|---|---|
| `lab_O0` | `-O0 -g -fno-omit-frame-pointer` |
| `lab_O3` | `-O3 -march=native -g -fno-omit-frame-pointer` |

Запуск усіх замірів: `bash measure.sh`. Усі виводи лежать у папці [`results/`](results/).

Вивід програми `lab_O0` ([results/run_O0.txt](results/run_O0.txt)):

```text
@@FILE:results/run_O0.txt@@
```

Вивід програми `lab_O3` ([results/run_O3.txt](results/run_O3.txt)):

```text
@@FILE:results/run_O3.txt@@
```

---

## 1. FlameGraph

### 1.1 Побудова

```bash
perf record -F 499 --call-graph dwarf -o perf_O0.data ./lab_O0
perf script -i perf_O0.data | ~/FlameGraph/stackcollapse-perf.pl | ~/FlameGraph/flamegraph.pl > flame_O0.svg
```

`perf record` 499 разів на секунду записує стек викликів; `--call-graph dwarf` відновлює стек за debug-інформацією (`-g`). `stackcollapse-perf.pl` згортає однакові стеки в один рядок з кількістю, `flamegraph.pl` малює SVG.

![FlameGraph lab_O0](results/flame_O0.svg)

Інтерактивна версія: відкрити [results/flame_O0.svg](results/flame_O0.svg) у браузері.

### 1.2 Інтерпретація

- Вісь Y — глибина стеку: знизу `main`, над ним функції, які він викликає.
- Ширина прямокутника — частка часу, коли функція була в стеку. Вісь X — алфавітний порядок, а не час.
- Плаский широкий верх — час іде в самій функції (власний час).
- `matmul` — найширший блок (@@PCT_O0_matmul@@ власного часу): потрійний цикл, n³ ≈ 10⁹ множень на один виклик.
- `branchy_sum` — @@PCT_O0_branchy_sum@@: одне порівняння на елемент, але дані випадкові, тому предиктор переходів помиляється ~50% разів.
- `saxpy` — @@PCT_O0_saxpy@@: проста арифметика, обмежена швидкістю читання пам'яті.
- `fib` — @@PCT_O0_fib@@: вузька, але висока «вежа» — глибина рекурсії до 40.

---

## 2. Параметри виконання

### 2.1 `/usr/bin/time --verbose ./lab_O0`

```text
@@FILE:results/time_O0.txt@@
```

| Поле | Значення |
|---|---|
| `Elapsed (wall clock)` | реальний час від старту до кінця: @@ELAPSED_O0@@ |
| `User time` ≈ `Elapsed` | програма весь час рахує на CPU, не чекає на диск чи мережу |
| `Maximum resident set size` | пікова пам'ять: 3 матриці по 4 МіБ + 2 вектори по 16 МіБ + масив 32 МіБ ≈ 80 МіБ |
| `context switches` | скільки разів ОС знімала процес з ядра |
| `Page faults` | звернення до нових сторінок пам'яті при першому записі у вектори |

Те саме для `lab_O3`:

```text
@@FILE:results/time_O3.txt@@
```

### 2.2 `perf stat -d ./lab_O0`

```text
@@FILE:results/stat_O0.txt@@
```

| Метрика | Формула / зміст |
|---|---|
| `cycles` | такти CPU; f ≈ cycles / t = @@CYC_O0@@ / @@TOT_O0@@ с ≈ @@FREQ_O0@@ ГГц |
| `instructions`, `insn per cycle` | IPC = instructions / cycles |
| `branch-misses` | % неправильно передбачених переходів (в основному `branchy_sum`) |
| `L1-dcache-load-misses` | % звернень, яких не було в кеші L1 (в основному `saxpy` і `matmul`) |

Те саме для `lab_O3`:

```text
@@FILE:results/stat_O3.txt@@
```

### 2.3 `perf report`

```bash
perf report -i perf_O0.data --stdio --no-children -g none
```

```text
@@FILE:results/report_top_O0.txt@@
```

Колонка `Overhead` — власний час функції (без дочірніх). Повний вивід: [results/report_O0.txt](results/report_O0.txt).

По бібліотеках (`--sort dso`):

```text
@@FILE:results/dso_O0.txt@@
```

@@DSO_O0@@ часу — у самому `lab_O0`, решта — ядро Linux і libc.

Те саме для `lab_O3` ([results/report_O3.txt](results/report_O3.txt)):

```text
@@FILE:results/report_top_O3.txt@@
```

---

## 3. Енергія

Вимірювання через Intel RAPL (лічильники енергії всередині CPU), кожен замір повторено @@R@@ рази (`-r @@R@@`), в таблицях — середнє:

```bash
perf stat -a -r 3 -e power/energy-pkg/,power/energy-cores/,power/energy-ram/ sleep 10      # простій
perf stat -a -r 3 -e power/energy-pkg/,power/energy-cores/,power/energy-ram/ ./lab_O0
```

| Домен | Що міряє |
|---|---|
| `energy-pkg` | весь процесор (ядра + кеш + контролер пам'яті + вбудована графіка) |
| `energy-cores` | лише ядра, це частина `pkg`, тому окремо не додається |
| `energy-ram` | модулі оперативної пам'яті |

### 3.1 Енергія системи

Простій ([results/energy_idle.txt](results/energy_idle.txt)):

```text
@@FILE:results/energy_idle.txt@@
```

Під час `lab_O0` ([results/energy_O0.txt](results/energy_O0.txt)):

```text
@@FILE:results/energy_O0.txt@@
```

Під час `lab_O3` ([results/energy_O3.txt](results/energy_O3.txt)):

```text
@@FILE:results/energy_O3.txt@@
```

```text
E_sys = E_pkg + E_ram
E_sys(O0) = @@E_PKG_O0@@ + @@E_RAM_O0@@ = @@Es_O0@@ Дж
E_sys(O3) = @@E_PKG_O3@@ + @@E_RAM_O3@@ = @@Es_O3@@ Дж
```

### 3.2 Енергія самої програми

`perf stat -a` рахує всю систему, тому віднімаю те, що система споживає без програми:

```text
P_idle = (E_pkg + E_ram)_idle / t_idle = (@@E_IDLE_PKG@@ + @@E_IDLE_RAM@@) / @@T_IDLE@@ = @@Pi@@ Вт

E_prog = E_sys − P_idle · t
E_prog(O0) = @@Es_O0@@ − @@Pi@@ · @@T_O0@@ = @@Ep_O0@@ Дж
E_prog(O3) = @@Es_O3@@ − @@Pi@@ · @@T_O3@@ = @@Ep_O3@@ Дж
```

Обмеження: RAPL не бачить дискретну відеокарту, дисплей і інші пристрої; вони під час тесту не навантажені, тому входять у `P_idle`.

---

## 4. -O0 проти -O3 -march=native

### 4.1 Асемблер

Повні лістинги: [asm/lab_O0.objdump.txt](asm/lab_O0.objdump.txt), [asm/lab_O3.objdump.txt](asm/lab_O3.objdump.txt).

`matmul`, -O0 — скалярні інструкції, 1 float за раз, кожна змінна йде через стек (`[rbp-…]`):

```text
@@FILE:results/asm_matmul_O0.txt@@
```

`matmul`, -O3 -march=native — 8 float за інструкцію в регістрах `ymm` (256 біт):

```text
@@FILE:results/asm_matmul_O3.txt@@
```

`branchy_sum`, -O0 — справжній умовний перехід:

```text
@@FILE:results/asm_branchy_O0.txt@@
```

`branchy_sum`, -O3 — `if` замінено маскою: `vpcmpgtd` порівнює 8 чисел, `vpand` обнуляє непотрібні, `vpaddq` додає. Переходу немає, отже немає й помилок передбачення:

```text
@@FILE:results/asm_branchy_O3.txt@@
```

#### 4.1.1 AVX / SIMD

`-march=native` дозволяє компілятору використати всі розширення цього CPU (AVX2, FMA). Звіт GCC (`make vecreport`), які цикли векторизовано:

```text
@@FILE:results/vecreport_short.txt@@
```

| Інструкція | Що робить |
|---|---|
| `vbroadcastss ymm, [..]` | копіює одне число `A[i][k]` у всі 8 слотів регістра |
| `vfmadd231ps ymm1, ymm2, [..]` | `ymm1 += ymm2 · mem` для 8 float за одну інструкцію (FMA) |
| `vpcmpgtd` | порівняння 8 int одночасно → маска |
| `vpand`, `vpaddq` | застосування маски і додавання до суми |

### 4.2 Метрики до і після

@@FILE:results/table_metrics.md@@

Час по функціях (з виводу програми) і частка в `perf report`:

@@FILE:results/table_functions.md@@

- Загальне прискорення ≈ @@SPEED@@× (@@TOT_O0@@ с → @@TOT_O3@@ с).
- `matmul` і `branchy_sum` прискорились найбільше: AVX2/FMA обробляє 8 значень за інструкцію, а `if` зник разом з помилками передбачення.
- `saxpy` прискорився менше: обмеження — пропускна здатність пам'яті, а не обчислення.
- `fib` не векторизується; прискорення лише від того, що змінні в регістрах, а не в стеку.
- Кількість інструкцій зменшилась в @@INSN_R@@ разів: одна AVX-інструкція замінює 8 скалярних.

### 4.3 Зміни FlameGraph

FlameGraph `lab_O3`:

![FlameGraph lab_O3](results/flame_O3.svg)

Частки змінились: `matmul` @@PCT_O0_matmul@@ → @@PCT_O3_matmul@@, `branchy_sum` @@PCT_O0_branchy_sum@@ → @@PCT_O3_branchy_sum@@, `saxpy` @@PCT_O0_saxpy@@ → @@PCT_O3_saxpy@@, `fib` @@PCT_O0_fib@@ → @@PCT_O3_fib@@. Після оптимізації вузьким місцем стає робота з пам'яттю (`saxpy`).

Диференційний FlameGraph (`difffolded.pl -n`, частки нормовані):

```bash
difffolded.pl -n a.folded b.folded | flamegraph.pl > flame_diff.svg
```

![FlameGraph O0 → O3](results/flame_diff.svg)

Синій — частка часу функції зменшилась після оптимізації, червоний — збільшилась.

### 4.4 Енергія до і після

@@FILE:results/table_energy.md@@

```text
E = P_avg · t
E_sys(O0) / E_sys(O3)   = @@Es_O0@@ / @@Es_O3@@ ≈ @@ESAVE@@
E_prog(O0) / E_prog(O3) = @@Ep_O0@@ / @@Ep_O3@@ ≈ @@EPSAVE@@
```

Середня потужність: @@P_O0@@ Вт (O0) і @@P_O3@@ Вт (O3), обидві версії завантажують одне ядро на 100%. Час скоротився в @@SPEED@@ разів, тому енергія на один запуск зменшилась в @@ESAVE@@ разів.

---

## Висновки

1. FlameGraph і `perf report` показали гарячі місця: `matmul`, `branchy_sum`, `saxpy`.
2. `-O3 -march=native` дав прискорення ≈ @@SPEED@@× завдяки AVX2/FMA (8 float за інструкцію) і заміні `if` на SIMD-маски.
3. Енергія системи на запуск зменшилась ≈ @@ESAVE@@×, енергія самої програми ≈ @@EPSAVE@@×: E = P·t, і головний внесок дає скорочення часу.
4. Після оптимізації обмеженням лишається пропускна здатність пам'яті (`saxpy`).
README_TEMPLATE