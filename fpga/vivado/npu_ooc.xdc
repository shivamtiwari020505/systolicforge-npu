## Out-of-context timing constraint for the complete SystolicForge NPU IP.
## This constrains internal register-to-register paths at 100 MHz. It does not
## model customer input/output delays and is not a board-level timing contract.
create_clock -name npu_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]
