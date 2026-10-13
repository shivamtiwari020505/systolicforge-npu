$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."
$buildDir = Join-Path $repoRoot "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
    $output = Join-Path $buildDir "tb_systolicforge_axi_lite.vvp"
    iverilog -g2012 -Wall -Wno-sensitivity-entire-array `
        -s tb_systolicforge_axi_lite -o $output `
        rtl\systolic_pe.sv `
        rtl\systolic_array.sv `
        rtl\systolicforge_sdp_ram.sv `
        rtl\systolicforge_npu.sv `
        rtl\scratchpad_dma.sv `
        rtl\systolicforge_soc.sv `
        rtl\systolicforge_axi_lite.sv `
        tb\tb_systolicforge_axi_lite.sv
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog compilation failed"
    }

    vvp $output
    if ($LASTEXITCODE -ne 0) {
        throw "AXI4-Lite integration simulation failed"
    }
}
finally {
    Pop-Location
}
