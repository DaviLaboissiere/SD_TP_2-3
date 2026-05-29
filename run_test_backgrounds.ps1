param (
    [Parameter(Mandatory=$true)][string]$File,
    [Parameter(Mandatory=$true)][int]$Block,
    [Parameter(Mandatory=$true)][int]$BasePort,
    [Parameter(Mandatory=$true)][int]$NumPeers,
    [string]$SeederFlag = "yes"
)

$Timeout = 120 # tempo limite em segundos

if ($SeederFlag -eq "yes" -and !(Test-Path $File)) {
    Write-Host "Erro: arquivo '$File' não encontrado." -ForegroundColor Red
    exit
}

# Cria pasta de logs
if (!(Test-Path "logs")) { New-Item -ItemType Directory -Force -Path "logs" | Out-Null }

Write-Host "Configuracao:" -ForegroundColor Cyan
Write-Host "  Arquivo: $File" -ForegroundColor Cyan
Write-Host "  Bloco: $Block bytes" -ForegroundColor Cyan
Write-Host "  Porta base: $BasePort" -ForegroundColor Cyan
Write-Host "  Numero de peers: $NumPeers" -ForegroundColor Cyan
Write-Host ""

$Processes = @()
$Logs = @()

# Inicia os Peers
for ($i = 0; $i -lt $NumPeers; $i++) {
    $Port = $BasePort + $i
    $LogPath = "$PWD\logs\peer_$Port.log"
    $Logs += $LogPath

    # Monta lista de vizinhos excluindo o próprio peer
    $NeighborsForThisPeer = @()
    for ($j = 0; $j -lt $NumPeers; $j++) {
        $NeighborPort = $BasePort + $j
        if ($NeighborPort -ne $Port) {
            $NeighborsForThisPeer += "127.0.0.1:$NeighborPort"
        }
    }
    $NeighborsList = $NeighborsForThisPeer -join ","
    
    Write-Host "Peer porta $Port -> vizinhos: $NeighborsList" -ForegroundColor Gray

    # Monta argumentos
    $ArgsList = @(
        "--ip", "127.0.0.1",
        "--port", "$Port",
        "--neighbors", "$NeighborsList",
        "--file", "$File",
        "--block-size", "$Block"
    )
    
    # Adiciona flag --seed apenas para o primeiro peer (se solicitado)
    if ($i -eq 0 -and $SeederFlag -eq "yes") {
        $ArgsList += "--seed"
        Write-Host "Iniciando Seeder na porta $Port" -ForegroundColor Green
    } else {
        Write-Host "Iniciando Leecher na porta $Port" -ForegroundColor Yellow
    }

    # Inicia o processo em background (sem mostrar comando completo para não poluir)
    $Proc = Start-Process -FilePath "python" -ArgumentList "peer.py $($ArgsList -join ' ')" -WindowStyle Hidden -PassThru -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.error"
    $Processes += $Proc
    
    # Aguarda um pouco entre inicializações para evitar conflitos
    Start-Sleep -Milliseconds 500
}

Write-Host "`nTodos os peers iniciados. Aguardando download" -ForegroundColor Cyan

# Se temos apenas 1 peer e é seeder, não há o que monitorar
if ($NumPeers -eq 1 -and $SeederFlag -eq "yes") {
    Write-Host "Seeder rodando em background" -ForegroundColor Cyan
    pause
    Write-Host "Encerrando seeder" -ForegroundColor Yellow
    foreach ($Proc in $Processes) {
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    exit
}

# Monitoramento do último Peer (Leecher)
$LeecherLog = $Logs[-1]
$SearchStr = "\[OK\] Integridade verificada"
$Found = $false
$Elapsed = 0

Write-Host "Monitorando conclusao do download (timeout=${Timeout}s)" -ForegroundColor Yellow
Write-Host "Aguardando leecher na porta $($BasePort + $NumPeers - 1)" -ForegroundColor Cyan

while ($Elapsed -lt $Timeout) {
    if (Test-Path $LeecherLog) {
        # Verifica se o arquivo de log contém a mensagem de sucesso
        $Match = Select-String -Path $LeecherLog -Pattern $SearchStr -Quiet
        if ($Match) {
            $Found = $true
            break
        }
        <#
        # Mostra progresso a cada 10 segundos
        if ($Elapsed % 10 -eq 0 -and $Elapsed -gt 0) {
            Write-Host "Ainda aguardando ($Elapsed segundos)" -ForegroundColor Gray
            # Mostra últimas linhas do log para debug
            $lastLines = Get-Content $LeecherLog -Tail 3 -ErrorAction SilentlyContinue
            if ($lastLines) {
                Write-Host "Últimas linhas do log:" -ForegroundColor Gray
                $lastLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
            }
        }#>
    }
    Start-Sleep -Seconds 2
    $Elapsed += 2
}

if (!$Found) {
    Write-Host "`nTimeout: download nao concluido em ${Timeout}s." -ForegroundColor Red
    Write-Host "`n=== Log do Leecher (ultimas 20 linhas) ===" -ForegroundColor Yellow
    if (Test-Path $LeecherLog) {
        Get-Content $LeecherLog -Tail 20
    } else {
        Write-Host "Log nao encontrado: $LeecherLog" -ForegroundColor Red
    }
} else {
    Write-Host "`nDownload concluido" -ForegroundColor Green
}

Write-Host "`nEncerrando todos os peers" -ForegroundColor Yellow
foreach ($Proc in $Processes) {
    try { 
        Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue 
        Write-Host "Processo $($Proc.Id) encerrado" -ForegroundColor Gray
    } catch {}
}

# Aguarda um pouco para os processos terminarem
Start-Sleep -Seconds 2

# Força encerramento de qualquer processo python remanescente
try { 
    $remaining = Get-Process python -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Host "Encerrando processos Python remanescentes" -ForegroundColor Gray
        Stop-Process -Name python -Force -ErrorAction SilentlyContinue
    }
} catch {}

# Resumo dos Logs
Write-Host "`n========== Resumo dos logs ==========" -ForegroundColor Cyan
for ($i = 0; $i -lt $NumPeers; $i++) {
    $Port = $BasePort + $i
    $Log = $Logs[$i]
    $PeerType = if ($i -eq 0 -and $SeederFlag -eq "yes") { "Seeder" } else { "Leecher" }
    Write-Host "--- $PeerType porta $Port (ultimas 5 linhas) ---" -ForegroundColor Yellow
    if (Test-Path $Log) {
        Get-Content $Log -Tail 5 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "(log vazio ou nao encontrado)"
    }
    Write-Host ""
}

Write-Host "Teste concluido" -ForegroundColor Cyan
