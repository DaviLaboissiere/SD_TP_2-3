#!/usr/bin/env python3
"""
peer.py – Nó de uma rede P2P de transferência de arquivos.
Cada peer atua como servidor e cliente simultaneamente.
Uso: python peer.py --ip 127.0.0.1 --port 5001 --neighbors 127.0.0.1:5002 --file arquivo.bin [--seed]
"""

import socket
import threading
import json
import struct
import hashlib
import argparse
import os
import time
import random
import sys

# ----------------------------------------------------------------------
# Protocolo: mensagens com cabeçalho [1 byte tipo][4 bytes tamanho][payload]
# Tipo 0 = JSON (controle)
# Tipo 1 = dados binários do bloco (índice + tamanho + conteúdo)
# ----------------------------------------------------------------------

def send_message(sock, msg_type, payload: bytes):
    """Envia uma mensagem enquadrada."""
    header = struct.pack('!B I', msg_type, len(payload))
    sock.sendall(header + payload)

def recv_message(sock):
    """Recebe uma mensagem enquadrada. Retorna (msg_type, payload)."""
    header = b''
    while len(header) < 5:
        chunk = sock.recv(5 - len(header))
        if not chunk:
            raise ConnectionError("Conexão fechada pelo par")
        header += chunk
    msg_type, length = struct.unpack('!B I', header)
    payload = b''
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise ConnectionError("Conexão fechada durante recepção")
        payload += chunk
    return msg_type, payload

# ----------------------------------------------------------------------
class Peer:
    def __init__(self, ip, port, neighbors, file_name, block_size=1024, seed=False):
        self.ip = ip
        self.port = port
        self.neighbors = neighbors          # lista de tuplas (ip, port)
        self.file_name = file_name
        self.block_size = block_size

        # Estado compartilhado
        self.lock = threading.Lock()
        self.metadata_ready = False
        self.total_blocks = 0
        self.file_size = 0
        self.checksum = None
        self.bitfield = []                  # lista de bool
        self.blocks = {}                    # índice -> bytes

        # Se for seeder inicial, carrega arquivo e divide em blocos
        if seed:
            self._init_seeder()

        # Threads
        self._all_done = threading.Event()
        self.server_thread = threading.Thread(target=self._run_server, daemon=True)
        self.client_threads = []

    def _init_seeder(self):
        """Seeder inicial: lê arquivo, divide em blocos, calcula checksum."""
        with open(self.file_name, 'rb') as f:
            data = f.read()
        self.file_size = len(data)
        self.checksum = hashlib.sha256(data).hexdigest()
        self.total_blocks = (self.file_size + self.block_size - 1) // self.block_size

        self.bitfield = [True] * self.total_blocks
        self.blocks = {}
        for i in range(self.total_blocks):
            start = i * self.block_size
            end = min(start + self.block_size, self.file_size)
            self.blocks[i] = data[start:end]
        self.metadata_ready = True
        print(f"[Seeder] Arquivo '{self.file_name}' carregado: {self.total_blocks} blocos, SHA256={self.checksum}")

    def _ensure_metadata(self, total_blocks, block_size, file_size, checksum):
        """Inicializa a estrutura de metadados (chamado pela primeira thread cliente que os recebe)."""
        with self.lock:
            if not self.metadata_ready:
                self.total_blocks = total_blocks
                self.block_size = block_size
                self.file_size = file_size
                self.checksum = checksum
                self.bitfield = [False] * total_blocks
                self.blocks = {}
                self.metadata_ready = True
                print(f"[Metadados] Arquivo: {total_blocks} blocos de {block_size} B, SHA256={checksum}")
                return True
            return False

    def _run_server(self):
        """Servidor: aceita conexões e cria uma thread por cliente."""
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind((self.ip, self.port))
        server_sock.listen(5)
        print(f"[Servidor] Ouvindo em {self.ip}:{self.port}")
        while not self._all_done.is_set():
            try:
                conn, addr = server_sock.accept()
                t = threading.Thread(target=self._handle_client, args=(conn, addr), daemon=True)
                t.start()
            except Exception as e:
                print(f"[Servidor] Erro ao aceitar: {e}")
        server_sock.close()

    def _handle_client(self, conn, addr):
        """Atende um peer conectado: handshake e requisições de blocos."""
        try:
            # 1. Aguarda HANDSHAKE
            msg_type, payload = recv_message(conn)
            if msg_type != 0:
                conn.close()
                return
            msg = json.loads(payload.decode('utf-8'))
            if msg.get('type') != 'handshake':
                conn.close()
                return
            file_req = msg.get('file_name')
            if file_req != self.file_name:
                resp = json.dumps({'type': 'error', 'message': 'Unknown file'}).encode()
                send_message(conn, 0, resp)
                conn.close()
                return

            # 2. Envia metadados (se souber)
            with self.lock:
                if not self.metadata_ready:
                    resp = json.dumps({'type': 'error', 'message': 'No metadata yet'}).encode()
                    send_message(conn, 0, resp)
                    conn.close()
                    return
                total_b = self.total_blocks
                bsize = self.block_size
                fsize = self.file_size
                csum = self.checksum

            handshake_ack = {
                'type': 'handshake_ack',
                'file_name': self.file_name,
                'block_size': bsize,
                'total_blocks': total_b,
                'file_size': fsize,
                'checksum': csum
            }
            send_message(conn, 0, json.dumps(handshake_ack).encode('utf-8'))
            print(f"[Servidor] Handshake OK com {addr}")

            # 3. Loop de atendimento de requisições de blocos
            while not self._all_done.is_set():
                msg_type, payload = recv_message(conn)
                if msg_type != 0:
                    break
                msg = json.loads(payload.decode('utf-8'))
                if msg.get('type') == 'request_block':
                    idx = msg['block_index']
                    with self.lock:
                        have = idx < len(self.bitfield) and self.bitfield[idx]
                    if have:
                        with self.lock:
                            data = self.blocks.get(idx, b'')
                        if data:
                            block_payload = struct.pack('!I', idx) + struct.pack('!I', len(data)) + data
                            send_message(conn, 1, block_payload)
                            print(f"[Servidor] Enviado bloco {idx} ({len(data)} B) para {addr}")
                        else:
                            # Nunca deveria acontecer, mas envia indisponível
                            send_message(conn, 0, json.dumps({'type': 'block_unavailable', 'block_index': idx}).encode())
                    else:
                        send_message(conn, 0, json.dumps({'type': 'block_unavailable', 'block_index': idx}).encode())
                else:
                    # Mensagem desconhecida
                    pass
        except (ConnectionError, Exception) as e:
            print(f"[Servidor] Conexão com {addr} encerrada: {e}")
        finally:
            conn.close()

    def _client_worker(self, neighbor_ip, neighbor_port):
        """Thread cliente: conecta ao vizinho e solicita blocos até completar o arquivo."""
        while not self._all_done.is_set():
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(5)
                sock.connect((neighbor_ip, neighbor_port))
                print(f"[Cliente] Conectado a {neighbor_ip}:{neighbor_port}")

                # Handshake
                handshake = json.dumps({'type': 'handshake', 'file_name': self.file_name}).encode()
                send_message(sock, 0, handshake)
                msg_type, payload = recv_message(sock)
                if msg_type != 0:
                    sock.close()
                    time.sleep(2)
                    continue
                resp = json.loads(payload.decode('utf-8'))
                if resp.get('type') != 'handshake_ack':
                    print(f"[Cliente] Vizinho {neighbor_ip}:{neighbor_port} respondeu erro: {resp.get('message')}")
                    sock.close()
                    time.sleep(2)
                    continue

                # Atualiza metadados, se necessário
                self._ensure_metadata(resp['total_blocks'], resp['block_size'],
                                      resp['file_size'], resp['checksum'])

                # Loop de requisição de blocos
                while not self._all_done.is_set():
                    # Escolhe um bloco que ainda não temos
                    with self.lock:
                        if not self.metadata_ready:
                            break
                        missing = [i for i, have in enumerate(self.bitfield) if not have]
                    if not missing:
                        # Todos os blocos foram baixados
                        self._all_done.set()
                        break

                    # Seleciona aleatoriamente entre os faltantes para evitar contenção
                    chosen = random.choice(missing)

                    # Faz a requisição
                    req = json.dumps({'type': 'request_block', 'block_index': chosen}).encode()
                    send_message(sock, 0, req)

                    # Recebe a resposta
                    rtype, rpayload = recv_message(sock)
                    if rtype == 0:
                        # JSON: provavelmente "block_unavailable"
                        resp_json = json.loads(rpayload.decode('utf-8'))
                        if resp_json.get('type') == 'block_unavailable':
                            # Continua tentando outro bloco
                            continue
                    elif rtype == 1:
                        # Dados binários do bloco
                        if len(rpayload) < 8:
                            continue
                        idx = struct.unpack('!I', rpayload[:4])[0]
                        dlen = struct.unpack('!I', rpayload[4:8])[0]
                        data = rpayload[8:8+dlen]
                        if len(data) != dlen:
                            continue
                        # Armazena bloco
                        with self.lock:
                            if idx < len(self.bitfield) and not self.bitfield[idx]:
                                self.blocks[idx] = data
                                self.bitfield[idx] = True
                                downloaded = sum(self.bitfield)
                                total = self.total_blocks
                                print(f"[Cliente] Bloco {idx} recebido de {neighbor_ip}:{neighbor_port} "
                                      f"({downloaded}/{total})")
                                if downloaded == total:
                                    self._all_done.set()
                                    break
                    else:
                        # Tipo desconhecido, ignora
                        pass

                sock.close()
                break   # Conexão encerrada com sucesso (todos os blocos obtidos)

            except (socket.timeout, ConnectionRefusedError, ConnectionError, OSError) as e:
                print(f"[Cliente] Falha na conexão com {neighbor_ip}:{neighbor_port}: {e}. Retentando em 2s...")
                time.sleep(2)
            except Exception as e:
                print(f"[Cliente] Erro inesperado com {neighbor_ip}:{neighbor_port}: {e}")
                time.sleep(2)
            finally:
                try:
                    sock.close()
                except:
                    pass

    def start(self):
        """Inicia servidor e threads clientes."""
        self.server_thread.start()
        
        # Só inicia threads clientes se NÃO for seeder
        if not self.metadata_ready:  # Seeder tem metadata_ready = True
            # Uma thread por vizinho
            for nip, nport in self.neighbors:
                t = threading.Thread(target=self._client_worker, args=(nip, nport), daemon=True)
                t.start()
                self.client_threads.append(t)
            
            # Aguarda até que todos os blocos sejam recebidos
            self._all_done.wait()
            self._assemble_and_verify()
        else:
            # Seeder: apenas mantém o servidor rodando
            print(f"[Seeder] Aguardando conexões de leechers para o arquivo '{self.file_name}'...")
            print("[Seeder] Pressione Ctrl+C para encerrar")
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                print("\n[Seeder] Encerrando servidor...")

    def _assemble_and_verify(self):
        """Monta o arquivo e verifica checksum."""
        with self.lock:
            if len(self.blocks) != self.total_blocks:
                print("[ERRO] Nem todos os blocos foram recebidos.")
                return
            # Ordena os blocos
            ordered = [self.blocks[i] for i in range(self.total_blocks)]
            data = b''.join(ordered)
        # Verifica checksum
        sha = hashlib.sha256(data).hexdigest()
        out_name = f"received_{self.file_name}"
        with open(out_name, 'wb') as f:
            f.write(data)
        print(f"\n[FINAL] Arquivo remontado: {out_name}")
        print(f"Tamanho: {len(data)} bytes")
        print(f"SHA256 original : {self.checksum}")
        print(f"SHA256 calculado: {sha}")
        if sha == self.checksum:
            print("[OK] Integridade verificada com sucesso!")
        else:
            print("[FALHA] Checksums não conferem.")

# ----------------------------------------------------------------------
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Peer P2P')
    parser.add_argument('--ip', required=True, help='Endereço IP deste peer')
    parser.add_argument('--port', type=int, required=True, help='Porta deste peer')
    parser.add_argument('--neighbors', required=True, help='Lista de vizinhos: ip1:port1,ip2:port2,...')
    parser.add_argument('--file', required=True, help='Nome do arquivo a compartilhar/baixar')
    parser.add_argument('--seed', action='store_true', help='Inicia como seeder (possui o arquivo completo)')
    parser.add_argument('--block-size', type=int, default=1024, help='Tamanho do bloco (padrão: 1024)')
    args = parser.parse_args()

    # Processa vizinhos
    neighbors = []
    print(f"[DEBUG] IP deste peer: {args.ip}, porta: {args.port}")
    print(f"[DEBUG] Lista bruta de vizinhos: {args.neighbors}")
    
    for token in args.neighbors.split(','):
        token = token.strip()
        if not token:
            continue
        ip, port = token.split(':')
        port = int(port)
        
        # Comparação normalizada (remove espaços e compara como string/numero)
        if ip.strip() == args.ip.strip() and port == args.port:
            print(f"[DEBUG] Ignorando próprio vizinho: {ip}:{port}")
            continue
            
        neighbors.append((ip, port))
    
    print(f"[DEBUG] Lista final de vizinhos: {neighbors}")
    print(f"[DEBUG] Modo seed: {args.seed}")
    
    peer = Peer(args.ip, args.port, neighbors, args.file, block_size=args.block_size, seed=args.seed)
    peer.start()
