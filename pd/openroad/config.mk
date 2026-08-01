export DESIGN_NAME = systolic_array_pd_top
export PLATFORM = sky130hd

SYSTOLICFORGE_PD_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SYSTOLICFORGE_ROOT := $(abspath $(SYSTOLICFORGE_PD_DIR)/../..)

export VERILOG_FILES = $(SYSTOLICFORGE_ROOT)/rtl/systolic_pe.sv \
                       $(SYSTOLICFORGE_ROOT)/rtl/systolic_array.sv \
                       $(SYSTOLICFORGE_ROOT)/pd/systolic_array_pd_top.sv
export SDC_FILE = $(SYSTOLICFORGE_ROOT)/pd/constraints.sdc

export CORE_UTILIZATION = 30
export CORE_ASPECT_RATIO = 1
export CORE_MARGIN = 2
export PLACE_DENSITY = 0.40
export TNS_END_PERCENT = 100
