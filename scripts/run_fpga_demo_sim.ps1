$ErrorActionPreference = "Stop"

$buildDir = Join-Path $PSScriptRoot "..\build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$output = Join-Path $buildDir "tb_fpga_demo.vvp"
iverilog -g2012 -Wall -s tb_fpga_demo -o $output `
    (Join-Path $PSScriptRoot "..\rtl\systolic_pe.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolic_array.sv") `
    (Join-Path $PSScriptRoot "..\fpga\common\systolicforge_fpga_demo.sv") `
    (Join-Path $PSScriptRoot "..\tb\tb_fpga_demo.sv")

if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed"
}

vvp $output
if ($LASTEXITCODE -ne 0) {
    throw "FPGA demo simulation failed"
}
