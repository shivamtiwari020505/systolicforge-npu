$ErrorActionPreference = "Stop"

$buildDir = Join-Path $PSScriptRoot "..\build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$output = Join-Path $buildDir "tb_systolicforge_npu.vvp"
iverilog -g2012 -Wall -Wno-sensitivity-entire-array -s tb_systolicforge_npu -o $output `
    (Join-Path $PSScriptRoot "..\rtl\systolic_pe.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolic_array.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolicforge_sdp_ram.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolicforge_npu.sv") `
    (Join-Path $PSScriptRoot "..\tb\tb_systolicforge_npu.sv")

if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed"
}

vvp $output
if ($LASTEXITCODE -ne 0) {
    throw "mini-NPU simulation failed"
}
