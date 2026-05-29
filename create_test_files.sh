#!/bin/bash
# Cria arquivos de teste com conteúdo aleatório
# Tamanhos: 10 KB, 20 KB, 1 MB, 5 MB, 10 MB, 20 MB
# Dê permissão para execução do script com chmod +x create_test_files.sh 
# Execute o scipt com ./create_test_files.sh
echo "Criando arquivos de teste..."

# File A: 10 KB (padrão) e 20 KB (variação)
dd if=/dev/urandom of=file_A_10K.bin bs=1024 count=10 status=none
dd if=/dev/urandom of=file_A_20K.bin bs=1024 count=20 status=none

# File B: 1 MB (padrão) e 5 MB (variação)
dd if=/dev/urandom of=file_B_1M.bin bs=1M count=1 status=none
dd if=/dev/urandom of=file_B_5M.bin bs=1M count=5 status=none

# File C: 10 MB (padrão) e 20 MB (variação)
dd if=/dev/urandom of=file_C_10M.bin bs=1M count=10 status=none
dd if=/dev/urandom of=file_C_20M.bin bs=1M count=20 status=none

echo "Arquivos criados:"
ls -lh file_*.bin
