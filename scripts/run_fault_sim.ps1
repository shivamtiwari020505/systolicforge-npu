$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."
$buildDir = Join-Path $repoRoot "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$output = Join-Path $buildDir "tb_fault_reporting.vvp"

Push-Location $repoRoot
try {
    iverilog -g2012 -Wall -Wno-sensitivity-entire-array `
        -s tb_fault_reporting -o $output `
        rtl\systolic_pe.sv `
        rtl\systolic_array.sv `
        rtl\systolicforge_sdp_ram.sv `
        rtl\systolicforge_npu.sv `
        rtl\scratchpad_dma.sv `
        rtl\systolicforge_soc.sv `
        tb\tb_fault_reporting.sv
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog compilation failed"
    }

    vvp $output
    if ($LASTEXITCODE -ne 0) {
        throw "fault-reporting simulation failed"
    }
}
finally {
    Pop-Location
}
