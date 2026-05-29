#!/bin/bash
# Uso: ./run_test_background.sh <arquivo> <tamanho_bloco> <porta_base> <num_peers> [seeder: yes/no]
# Exemplo: ./run_test_background.sh file_A_10K.bin 1024 5000 2 yes

FILE="$1"
BLOCK="$2"
BASE_PORT="$3"
NUM_PEERS="$4"
SEEDER_FLAG="${5:-yes}"
TIMEOUT=120   # tempo máximo de espera em segundos

if [ $# -lt 4 ]; then
    echo "Uso: $0 <arquivo> <tamanho_bloco> <porta_base> <num_peers> [seeder: yes/no]"
    exit 1  
fi

# Valida se o arquivo de origem existe (para o seeder)
if [ "$SEEDER_FLAG" = "yes" ] && [ ! -f "$FILE" ]; then
    echo "Erro: arquivo '$FILE' não encontrado para o seeder."
    exit 1
fi

# Monta lista de vizinhos (todos os peers na faixa de portas)
NEIGHBORS=""
for ((i=0; i<NUM_PEERS; i++)); do
    PORT=$((BASE_PORT + i))
    [ $i -ne 0 ] && NEIGHBORS+=","
    NEIGHBORS+="127.0.0.1:${PORT}"
done

mkdir -p logs
PIDS=()
LOGS=()   # guarda os caminhos dos logs para consulta posterior

# Lança cada peer usando bash -c para garantir redirecionamento correto
for ((i=0; i<NUM_PEERS; i++)); do
    PORT=$((BASE_PORT + i))
    LOG="logs/peer_${PORT}.log"
    LOGS+=("$LOG")
    
    # Comando base do peer
    CMD="python3 peer.py --ip 127.0.0.1 --port ${PORT} --neighbors ${NEIGHBORS} --file ${FILE} --block-size ${BLOCK}"
    if [ $i -eq 0 ] && [ "$SEEDER_FLAG" = "yes" ]; then
        CMD+=" --seed"
    fi

    echo "Iniciando Peer ${PORT} (log: ${LOG})"
    # A chave é usar bash -c com redirecionamento explícito dentro da string
    bash -c "$CMD > \"$LOG\" 2>&1" &
    PIDS+=($!)
    sleep 0.5
done

# ---------- Aguarda conclusão do download ----------
LEECHER_IDX=$((NUM_PEERS - 1))              # último peer como leecher
LEECHER_LOG="${LOGS[$LEECHER_IDX]}"
SEARCH_STR="[OK] Integridade verificada com sucesso"
FOUND=0
ELAPSED=0

echo "Monitorando conclusão do download (timeout=${TIMEOUT}s)..."
while [ $ELAPSED -lt $TIMEOUT ]; do
    if grep -q "$SEARCH_STR" "$LEECHER_LOG" 2>/dev/null; then
        FOUND=1
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $FOUND -eq 0 ]; then
    echo "Timeout: download não concluído em ${TIMEOUT}s. Verifique os logs."
    echo "Encerrando todos os peers forçadamente..."
else
    echo "Download concluído! Encerrando peers..."
fi

# Mata todos os processos iniciados
kill "${PIDS[@]}" 2>/dev/null
wait "${PIDS[@]}" 2>/dev/null   # recolhe os zumbis

# ---------- Exibe resumo dos logs ----------
echo ""
echo "========== Resumo dos logs =========="
for i in $(seq 0 $((NUM_PEERS - 1))); do
    PORT=$((BASE_PORT + i))
    LOG="${LOGS[$i]}"
    echo "--- Peer porta ${PORT} (últimas 5 linhas) ---"
    if [ -s "$LOG" ]; then
        tail -n 5 "$LOG"
    else
        echo "(log vazio)"
    fi
    echo ""
done
