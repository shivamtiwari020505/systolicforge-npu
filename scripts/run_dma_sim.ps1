$ErrorActionPreference = "Stop"

$buildDir = Join-Path $PSScriptRoot "..\build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$output = Join-Path $buildDir "tb_scratchpad_dma.vvp"
iverilog -g2012 -Wall -s tb_scratchpad_dma -o $output `
    (Join-Path $PSScriptRoot "..\rtl\scratchpad_dma.sv") `
    (Join-Path $PSScriptRoot "..\tb\tb_scratchpad_dma.sv")

if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed"
}

vvp $output
if ($LASTEXITCODE -ne 0) {
    throw "DMA simulation failed"
}
