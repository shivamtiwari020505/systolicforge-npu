$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."
$buildDir = Join-Path $repoRoot "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$output = Join-Path $buildDir "memory_foundation.vvp"
iverilog -g2012 -Wall -s tb_systolicforge_sdp_ram -o $output `
    (Join-Path $repoRoot "rtl\systolicforge_sdp_ram.sv") `
    (Join-Path $repoRoot "tb\tb_systolicforge_sdp_ram.sv")
if ($LASTEXITCODE -ne 0) {
    throw "memory-foundation compilation failed"
}

vvp $output
if ($LASTEXITCODE -ne 0) {
    throw "memory-foundation simulation failed"
}
