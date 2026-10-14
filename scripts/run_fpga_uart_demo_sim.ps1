$ErrorActionPreference = "Stop"

$buildDir = Join-Path $PSScriptRoot "..\build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$output = Join-Path $buildDir "tb_fpga_uart_demo.vvp"
iverilog -g2012 -Wall -Wno-sensitivity-entire-array `
    -s tb_fpga_uart_demo -o $output `
    (Join-Path $PSScriptRoot "..\rtl\systolic_pe.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolic_array.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolicforge_matmul_validator.sv") `
    (Join-Path $PSScriptRoot "..\fpga\common\systolicforge_fpga_engine.sv") `
    (Join-Path $PSScriptRoot "..\fpga\common\systolicforge_uart_rx.sv") `
    (Join-Path $PSScriptRoot "..\fpga\common\systolicforge_uart_tx.sv") `
    (Join-Path $PSScriptRoot "..\fpga\common\systolicforge_fpga_uart_demo.sv") `
    (Join-Path $PSScriptRoot "..\tb\tb_fpga_uart_demo.sv")

if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed"
}

vvp $output
if ($LASTEXITCODE -ne 0) {
    throw "UART FPGA demo simulation failed"
}
