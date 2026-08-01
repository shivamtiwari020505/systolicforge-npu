PYTHON ?= python3
YOSYS ?= yosys
YOSYS_DATDIR ?= /usr/share/yosys

.PHONY: test core npu dma fpga-demo compiled-e2e compiler synth gate-sim synth-xc7

test: core npu dma fpga-demo compiler compiled-e2e

build:
	mkdir -p build

core: build
	iverilog -g2012 -Wall -s tb_systolic_array -o build/core.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv tb/tb_systolic_array.sv
	vvp build/core.vvp

npu: build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_systolicforge_npu -o build/npu.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_npu.sv \
		tb/tb_systolicforge_npu.sv
	vvp build/npu.vvp

dma: build
	iverilog -g2012 -Wall -s tb_scratchpad_dma -o build/dma.vvp \
		rtl/scratchpad_dma.sv tb/tb_scratchpad_dma.sv
	vvp build/dma.vvp

fpga-demo: build
	iverilog -g2012 -Wall -s tb_fpga_demo -o build/fpga_demo.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv \
		fpga/common/systolicforge_fpga_demo.sv tb/tb_fpga_demo.sv
	vvp build/fpga_demo.vvp

compiler:
	$(PYTHON) -m unittest discover -s tests -v
	$(PYTHON) compiler/systolicforge_compile.py examples/matmul.json -o build/example_program

compiled-e2e: build
	$(PYTHON) compiler/systolicforge_compile.py examples/matmul.json -o build/example_program
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_compiled_program -o build/compiled_program.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_npu.sv \
		tb/tb_compiled_program.sv
	vvp build/compiled_program.vvp

synth: build
	$(YOSYS) -l build/yosys_synth.log -s synth/yosys_synth.ys

gate-sim: synth
	iverilog -g2012 -DGATE_SIM -s tb_systolic_array -o build/gate_core.vvp \
		$(YOSYS_DATDIR)/simcells.v build/systolic_array_netlist.v \
		tb/tb_systolic_array.sv
	vvp build/gate_core.vvp

synth-xc7: build
	$(YOSYS) -l build/yosys_xc7_synth.log -s synth/yosys_xc7_synth.ys
