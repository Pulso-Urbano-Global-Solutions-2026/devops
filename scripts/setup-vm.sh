#!/bin/bash
# =========================================================
# PULSO URBANO — Setup de VM Cloud
# Testado em: Ubuntu 22.04 LTS (Oracle Cloud Free Tier)
# =========================================================

set -e

echo "=== PULSO URBANO — SETUP VM ==="

# 1. Instalar Docker
echo "[1/5] Instalando Docker..."
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# 2. Clonar repo com submodulos
echo "[2/5] Clonando repositório com submodulos..."
git clone --recurse-submodules https://github.com/Pulso-Urbano-Global-Solutions-2026/devops.git
cd devops

# 3. Configurar variáveis de ambiente
echo "[3/5] Configurando .env..."
cp .env.example .env
echo "EDITE o .env com suas credenciais antes de continuar"
echo "Pressione ENTER quando estiver pronto..."
read

# 4. Subir containers em background (obrigatório — modo background perde -0.5 ponto)
echo "[4/5] Subindo containers em modo background..."
docker compose up -d --build

# 5. Verificar status
echo "[5/5] Verificando containers..."
docker compose ps
docker compose logs --tail=20

echo "=== SETUP CONCLUÍDO ==="
echo "Java API:  http://$(curl -s ifconfig.me):8080"
echo ".NET API:  http://$(curl -s ifconfig.me):5000"
echo "Oracle:    $(curl -s ifconfig.me):1521"
