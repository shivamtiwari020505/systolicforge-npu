$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."
$buildDir = Join-Path $repoRoot "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
    $output = Join-Path $buildDir "tb_systolic_array_arithmetic_edges.vvp"
    iverilog -g2012 -Wall `
        -s tb_systolic_array_arithmetic_edges -o $output `
        rtl\systolic_pe.sv `
        rtl\systolic_array.sv `
        tb\tb_systolic_array_arithmetic_edges.sv
    if ($LASTEXITCODE -ne 0) {
        throw "array arithmetic edge-case compilation failed"
    }

    vvp $output
    if ($LASTEXITCODE -ne 0) {
        throw "array arithmetic edge-case simulation failed"
    }
}
finally {
    Pop-Location
}
