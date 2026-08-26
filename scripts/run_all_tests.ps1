$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "run_core_sim.ps1")
& (Join-Path $PSScriptRoot "run_array_edge_cases_sim.ps1")
& (Join-Path $PSScriptRoot "run_npu_sim.ps1")
& (Join-Path $PSScriptRoot "run_dma_sim.ps1")
& (Join-Path $PSScriptRoot "run_fault_sim.ps1")
& (Join-Path $PSScriptRoot "run_axi_lite_sim.ps1")
& (Join-Path $PSScriptRoot "run_fpga_demo_sim.ps1")
& (Join-Path $PSScriptRoot "run_fpga_engine_sim.ps1")
& (Join-Path $PSScriptRoot "run_fpga_uart_demo_sim.ps1")
& (Join-Path $PSScriptRoot "run_compiled_program_sim.ps1")
& (Join-Path $PSScriptRoot "run_soc_sim.ps1")
& (Join-Path $PSScriptRoot "run_randomized_differential.ps1")

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
