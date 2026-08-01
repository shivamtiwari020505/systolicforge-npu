$ErrorActionPreference = "Stop"

$buildDir = Join-Path $PSScriptRoot "..\build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$output = Join-Path $buildDir "tb_systolic_array.vvp"
iverilog -g2012 -Wall -s tb_systolic_array -o $output `
    (Join-Path $PSScriptRoot "..\rtl\systolic_pe.sv") `
    (Join-Path $PSScriptRoot "..\rtl\systolic_array.sv") `
    (Join-Path $PSScriptRoot "..\tb\tb_systolic_array.sv")

if ($LASTEXITCODE -ne 0) {
    throw "iverilog compilation failed"
}

vvp $output
if ($LASTEXITCODE -ne 0) {
    throw "systolic array simulation failed"
}
