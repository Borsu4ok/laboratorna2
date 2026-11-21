
CXX     = g++
DBG     = -g -fno-omit-frame-pointer
CFLAGS0 = -O0 $(DBG)
CFLAGS3 = -O3 -march=native $(DBG)
CFLAGSS = -O3 $(DBG)

all: lab_O0 lab_O3 lab_O3sse

lab_O0: lab.cpp
	$(CXX) $(CFLAGS0) -o $@ $<

lab_O3: lab.cpp
	$(CXX) $(CFLAGS3) -o $@ $<

lab_O3sse: lab.cpp
	$(CXX) $(CFLAGSS) -o $@ $<

asm: all
	mkdir -p asm
	$(CXX) $(CFLAGS0) -S -masm=intel -fverbose-asm -o asm/lab_O0.s lab.cpp
	$(CXX) $(CFLAGS3) -S -masm=intel -fverbose-asm -o asm/lab_O3.s lab.cpp
	$(CXX) $(CFLAGSS) -S -masm=intel -fverbose-asm -o asm/lab_O3sse.s lab.cpp
	for b in lab_O0 lab_O3 lab_O3sse; do \
	  objdump -d --no-show-raw-insn -M intel -S $$b > asm/$$b.objdump.txt; done

vecreport: lab.cpp
	$(CXX) $(CFLAGS3) -fopt-info-vec-optimized -c -o /dev/null lab.cpp

clean:
	rm -f lab_O0 lab_O3 lab_O3sse perf_*.data* out_*.perf *.folded

.PHONY: all asm vecreport clean
