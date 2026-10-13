$ErrorActionPreference = "Stop"
Push-Location (Join-Path $PSScriptRoot "..")
try {
    New-Item -ItemType Directory -Force -Path build | Out-Null
    iverilog -g2012 -Wall -Wno-sensitivity-entire-array -s tb_npu_memory_redesign `
        -o build\memory_redesign.vvp rtl\systolic_pe.sv rtl\systolic_array.sv `
        rtl\systolicforge_sdp_ram.sv rtl\systolicforge_npu.sv `
        tb\reference\systolicforge_npu_legacy.sv tb\tb_npu_memory_redesign.sv
    if ($LASTEXITCODE -ne 0) { throw "memory comparison compilation failed" }
    vvp build\memory_redesign.vvp
    if ($LASTEXITCODE -ne 0) { throw "memory comparison simulation failed" }
}
finally { Pop-Location }
