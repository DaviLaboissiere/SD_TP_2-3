Write-Host "Criando arquivos de teste..." -ForegroundColor Cyan

function Create-RandomFile($filename, $sizeInBytes) {
    $bytes = New-Object byte[] $sizeInBytes
    $rand = New-Object Random
    $rand.NextBytes($bytes)
    [System.IO.File]::WriteAllBytes("$PWD\$filename", $bytes)
    $kb = [math]::Round($sizeInBytes / 1024, 2)
    Write-Host "Criado: $filename ($kb KB)"
}

# File A: 10 KB e 20 KB
Create-RandomFile "file_A_10K.bin" (10 * 1024)
Create-RandomFile "file_A_20K.bin" (20 * 1024)

# File B: 1 MB e 5 MB
Create-RandomFile "file_B_1M.bin" (1 * 1024 * 1024)
Create-RandomFile "file_B_5M.bin" (5 * 1024 * 1024)

# File C: 10 MB e 20 MB
Create-RandomFile "file_C_10M.bin" (10 * 1024 * 1024)
Create-RandomFile "file_C_20M.bin" (20 * 1024 * 1024)

Write-Host "Arquivos criados" -ForegroundColor Green
