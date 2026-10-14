$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $repoRoot
try {
    New-Item -ItemType Directory -Force build | Out-Null
    iverilog -g2012 -Wall -s tb_matmul_validator -o build/validator.vvp `
        rtl/systolicforge_matmul_validator.sv tb/tb_matmul_validator.sv
    if ($LASTEXITCODE -ne 0) { throw 'Validator compilation failed' }
    vvp build/validator.vvp
    if ($LASTEXITCODE -ne 0) { throw 'Validator regression failed' }
} finally { Pop-Location }
