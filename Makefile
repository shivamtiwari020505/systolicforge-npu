PYTHON ?= python3
YOSYS ?= yosys
YOSYS_DATDIR ?= /usr/share/yosys

.PHONY: test core array-edges memory-foundation memory-foundation-synth npu dma faults axi-lite fpga-demo fpga-engine fpga-uart-demo compiled-e2e soc-e2e random-diff compiler lint synth gate-sim synth-xc7 waveforms diagrams evidence

test: core array-edges validator memory-foundation memory-redesign npu dma faults axi-lite fpga-demo fpga-engine fpga-uart-demo compiler compiled-e2e soc-e2e random-diff

.PHONY: validator
validator: build
	iverilog -g2012 -Wall -s tb_matmul_validator -o build/validator.vvp \
		rtl/systolicforge_matmul_validator.sv tb/tb_matmul_validator.sv
	vvp build/validator.vvp

build:
	mkdir -p build

core: build
	iverilog -g2012 -Wall -s tb_systolic_array -o build/core.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv tb/tb_systolic_array.sv
	vvp build/core.vvp

array-edges: build
	iverilog -g2012 -Wall -s tb_systolic_array_arithmetic_edges \
		-o build/array_edges.vvp rtl/systolic_pe.sv rtl/systolic_array.sv \
		tb/tb_systolic_array_arithmetic_edges.sv
	vvp build/array_edges.vvp

memory-foundation: build
	iverilog -g2012 -Wall -s tb_systolicforge_sdp_ram \
		-o build/memory_foundation.vvp rtl/systolicforge_sdp_ram.sv \
		tb/tb_systolicforge_sdp_ram.sv
	vvp build/memory_foundation.vvp

memory-foundation-synth: build
	$(YOSYS) -l build/yosys_memory_foundation.log \
		-s synth/yosys_memory_foundation.ys

.PHONY: memory-redesign synth-npu-full
memory-redesign: build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_npu_memory_redesign -o build/memory_redesign.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv \
		rtl/systolicforge_npu.sv tb/reference/systolicforge_npu_legacy.sv \
		tb/tb_npu_memory_redesign.sv
	vvp build/memory_redesign.vvp

synth-npu-full: build
	$(YOSYS) -l build/yosys_npu_full.log -s synth/yosys_npu_full.ys

npu: build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_systolicforge_npu -o build/npu.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		tb/tb_systolicforge_npu.sv
	vvp build/npu.vvp

dma: build
	iverilog -g2012 -Wall -s tb_scratchpad_dma -o build/dma.vvp \
		rtl/scratchpad_dma.sv tb/tb_scratchpad_dma.sv
	vvp build/dma.vvp

faults: build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_fault_reporting -o build/faults.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv \
		tb/tb_fault_reporting.sv
	vvp build/faults.vvp

axi-lite: build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_systolicforge_axi_lite -o build/axi_lite.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv \
		rtl/systolicforge_axi_lite.sv tb/tb_systolicforge_axi_lite.sv
	vvp build/axi_lite.vvp

fpga-demo: build
	iverilog -g2012 -Wall -s tb_fpga_demo -o build/fpga_demo.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv \
		fpga/common/systolicforge_fpga_demo.sv tb/tb_fpga_demo.sv
	vvp build/fpga_demo.vvp

fpga-engine: build
	$(PYTHON) compiler/systolicforge_compile.py examples/matmul.json \
		-o build/example_program --array-rows 8 --array-cols 8 \
		--scratchpad-depth 128 --imem-depth 16
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array -DFPGA_ENGINE \
		-s tb_compiled_program -o build/fpga_engine.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv \
		fpga/common/systolicforge_fpga_engine.sv tb/tb_compiled_program.sv
	vvp build/fpga_engine.vvp

fpga-uart-demo: build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_fpga_uart_demo -o build/fpga_uart_demo.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv \
		fpga/common/systolicforge_fpga_engine.sv \
		fpga/common/systolicforge_uart_rx.sv \
		fpga/common/systolicforge_uart_tx.sv \
		fpga/common/systolicforge_fpga_uart_demo.sv tb/tb_fpga_uart_demo.sv
	vvp build/fpga_uart_demo.vvp

compiler:
	$(PYTHON) -m unittest discover -s tests -v
	$(PYTHON) compiler/systolicforge_compile.py examples/matmul.json -o build/example_program

lint:
	verilator --lint-only --timing -Wall \
		-Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
		--top-module systolicforge_soc \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv
	verilator --lint-only --timing -Wall \
		-Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
		--top-module systolicforge_axi_lite \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv \
		rtl/systolicforge_axi_lite.sv
	verilator --lint-only --timing -Wall \
		-Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		--top-module systolicforge_fpga_uart_demo \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv \
		fpga/common/systolicforge_fpga_engine.sv \
		fpga/common/systolicforge_uart_rx.sv \
		fpga/common/systolicforge_uart_tx.sv \
		fpga/common/systolicforge_fpga_uart_demo.sv

compiled-e2e: build
	$(PYTHON) compiler/systolicforge_compile.py examples/matmul.json -o build/example_program
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_compiled_program -o build/compiled_program.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		tb/tb_compiled_program.sv
	vvp build/compiled_program.vvp

soc-e2e: build
	$(PYTHON) compiler/systolicforge_compile.py examples/matmul.json -o build/example_program
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_systolicforge_soc -o build/soc.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv \
		tb/tb_systolicforge_soc.sv
	vvp build/soc.vvp
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_systolicforge_soc -Ptb_systolicforge_soc.ADDR_W=7 \
		-o build/soc_ooc_compact.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv \
		tb/tb_systolicforge_soc.sv
	vvp build/soc_ooc_compact.vvp
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array \
		-s tb_systolicforge_soc -Ptb_systolicforge_soc.ADDR_W=12 \
		-Ptb_systolicforge_soc.IMEM_DEPTH=256 -o build/soc_full.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv \
		rtl/systolicforge_npu.sv rtl/scratchpad_dma.sv rtl/systolicforge_soc.sv \
		tb/tb_systolicforge_soc.sv
	vvp build/soc_full.vvp

random-diff: build
	$(PYTHON) scripts/run_randomized_differential.py

synth: build
	$(YOSYS) -l build/yosys_synth.log -s synth/yosys_synth.ys

gate-sim: synth
	iverilog -g2012 -DGATE_SIM -s tb_systolic_array -o build/gate_core.vvp \
		$(YOSYS_DATDIR)/simcells.v build/systolic_array_netlist.v \
		tb/tb_systolic_array.sv
	vvp build/gate_core.vvp

synth-xc7: build
	$(YOSYS) -l build/yosys_xc7_synth.log -s synth/yosys_xc7_synth.ys

waveforms: build
	mkdir -p build/waves docs/diagrams
	iverilog -g2012 -Wall -DDUMP_VCD -s tb_systolic_array \
		-o build/waves/core.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv tb/tb_systolic_array.sv
	vvp build/waves/core.vvp
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array -DDUMP_VCD \
		-s tb_systolicforge_npu -o build/waves/npu.vvp \
		rtl/systolic_pe.sv rtl/systolic_array.sv rtl/systolicforge_matmul_validator.sv rtl/systolicforge_sdp_ram.sv rtl/systolicforge_npu.sv \
		tb/tb_systolicforge_npu.sv
	vvp build/waves/npu.vvp
	$(PYTHON) scripts/render_waveforms.py build/waves docs/diagrams

diagrams:
	mkdir -p docs/diagrams
	dot -Tsvg docs/diagrams/system_architecture.dot \
		-o docs/diagrams/system_architecture.svg
	dot -Tsvg docs/diagrams/array_microarchitecture.dot \
		-o docs/diagrams/array_microarchitecture.svg

evidence: test lint gate-sim memory-foundation-synth synth-npu-full synth-xc7 waveforms diagrams
