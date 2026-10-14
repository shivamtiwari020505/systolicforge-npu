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

    # Exercise original, compact, and full default scratchpad/IMEM capacities.
    foreach ($addressWidth in @(8, 7, 12)) {
        $instructionDepth = if ($addressWidth -eq 12) { 256 } else { 16 }
        $output = Join-Path $buildDir "tb_systolicforge_soc_a$addressWidth.vvp"
        iverilog -g2012 -Wall -Wno-sensitivity-entire-array `
            -s tb_systolicforge_soc "-Ptb_systolicforge_soc.ADDR_W=$addressWidth" `
            "-Ptb_systolicforge_soc.IMEM_DEPTH=$instructionDepth" -o $output `
            rtl\systolic_pe.sv `
            rtl\systolic_array.sv `
            rtl\systolicforge_matmul_validator.sv `
            rtl\systolicforge_sdp_ram.sv `
            rtl\systolicforge_npu.sv `
            rtl\scratchpad_dma.sv `
            rtl\systolicforge_soc.sv `
            tb\tb_systolicforge_soc.sv
        if ($LASTEXITCODE -ne 0) {
            throw "iverilog compilation failed"
        }

        vvp $output
        if ($LASTEXITCODE -ne 0) {
            throw "integrated SoC simulation failed"
        }
    }
}
finally {
    Pop-Location
}
