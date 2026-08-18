$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "run_core_sim.ps1")
& (Join-Path $PSScriptRoot "run_npu_sim.ps1")
& (Join-Path $PSScriptRoot "run_dma_sim.ps1")
& (Join-Path $PSScriptRoot "run_fpga_demo_sim.ps1")
& (Join-Path $PSScriptRoot "run_compiled_program_sim.ps1")
& (Join-Path $PSScriptRoot "run_soc_sim.ps1")

Push-Location (Join-Path $PSScriptRoot "..")
try {
    python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) {
        throw "compiler tests failed"
    }

}
finally {
    Pop-Location
}
