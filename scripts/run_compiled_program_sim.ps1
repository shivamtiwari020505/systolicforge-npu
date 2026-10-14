$ErrorActionPreference = "Stop"

$repoRoot = Join-Path $PSScriptRoot ".."
$buildDir = Join-Path $repoRoot "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
    python compiler\systolicforge_compile.py examples\matmul.json `
        -o build\example_program --array-rows 8 --array-cols 8
    if ($LASTEXITCODE -ne 0) {
        throw "example compilation failed"
    }

    $output = Join-Path $buildDir "tb_compiled_program.vvp"
    iverilog -g2012 -Wall -Wno-sensitivity-entire-array `
        -s tb_compiled_program -o $output `
        rtl\systolic_pe.sv `
        rtl\systolic_array.sv `
        rtl\systolicforge_matmul_validator.sv `
        rtl\systolicforge_sdp_ram.sv `
        rtl\systolicforge_npu.sv `
        tb\tb_compiled_program.sv
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog compilation failed"
    }

    vvp $output
    if ($LASTEXITCODE -ne 0) {
        throw "compiled-program RTL simulation failed"
    }
}
finally {
    Pop-Location
}
