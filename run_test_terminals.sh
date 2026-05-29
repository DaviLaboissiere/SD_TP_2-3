#!/bin/bash
# Uso: ./run_test_terminals.sh <arquivo> <tamanho_bloco> <porta_base> <num_peers> <seeder_opcional>
# Exemplo: ./run_test_terminals.sh file_A_10K.bin 1024 5000 2 yes

FILE="$1"
BLOCK="$2"
BASE_PORT="$3"
NUM_PEERS="$4"
SEEDER_FLAG="${5:-yes}"   # "yes" se o primeiro peer deve ser seeder

if [ $# -lt 4 ]; then
    echo "Uso: $0 <arquivo> <tamanho_bloco> <porta_base> <num_peers> [seeder: yes/no]"
    exit 1
fi

# Lista de vizinhos: todos os peers com porta de BASE_PORT até BASE_PORT+NUM_PEERS-1
NEIGHBORS=""
for ((i=0; i<NUM_PEERS; i++)); do
    PORT=$((BASE_PORT + i))
    if [ $i -ne 0 ]; then
        NEIGHBORS+=","
    fi
    NEIGHBORS+="127.0.0.1:${PORT}"
done

# Verifica emulador disponível
if command -v gnome-terminal &> /dev/null; then
    TERM_CMD="gnome-terminal -- bash -c"
elif command -v xterm &> /dev/null; then
    TERM_CMD="xterm -e bash -c"
elif command -v konsole &> /dev/null; then
    TERM_CMD="konsole -e bash -c"
else
    echo "Nenhum emulador de terminal encontrado (gnome-terminal, xterm ou konsole). Use o script de background."
    exit 1
fi

mkdir -p logs

for ((i=0; i<NUM_PEERS; i++)); do
    PORT=$((BASE_PORT + i))
    LOG="logs/peer_${PORT}.log"

    # Monta comando Python
    CMD="python3 peer.py --ip 127.0.0.1 --port ${PORT} --neighbors ${NEIGHBORS} --file ${FILE} --block-size ${BLOCK}"
    if [ $i -eq 0 ] && [ "$SEEDER_FLAG" = "yes" ]; then
        CMD+=" --seed"
    fi
    CMD+=" 2>&1 | tee ${LOG}"
    
    echo "Lançando Peer ${PORT}: ${CMD}"
    $TERM_CMD "$CMD" &
    sleep 1
done

echo "Todos os peers iniciados. Logs em logs/peer_<porta>.log"
