#!/bin/bash
# =============================================================================
# PULSO URBANO — setup-vm.sh
# Setup manual dentro da VM (use se preferir SSH direto ao invés do deploy-azure.sh)
# Testado em: Ubuntu 22.04 LTS x86_64
# =============================================================================
set -euo pipefail

echo "========================================================"
echo " PULSO URBANO — Setup manual da VM"
echo "========================================================"

# ─── [1/5] Docker via apt (nao curl|sh) ──────────────────────────────────────
echo ""
echo "[1/5] Instalando Docker Engine via repositorio oficial..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "  Docker: $(docker --version)"
echo "  Compose: $(docker compose version)"

# ─── [2/5] Clonar com submodulos ─────────────────────────────────────────────
echo ""
echo "[2/5] Clonando repositório com submodulos..."
mkdir -p /opt/pulso-urbano
git clone --recurse-submodules \
    https://github.com/Pulso-Urbano-Global-Solutions-2026/devops.git \
    /opt/pulso-urbano
cd /opt/pulso-urbano

echo "  Submodulos:"
ls java-api/  | head -3
ls dotnet-api/ | head -3

# ─── [3/5] Configurar .env ───────────────────────────────────────────────────
echo ""
echo "[3/5] Configurando .env..."
cp .env.example .env
echo ""
echo "  ┌─────────────────────────────────────────────────────"
echo "  │  AÇÃO NECESSÁRIA: edite o .env antes de continuar."
echo "  │  nano /opt/pulso-urbano/.env"
echo "  │"
echo "  │  Valores obrigatórios:"
echo "  │    JWT_SECRET=$(openssl rand -base64 64 | tr -d '\n')"
echo "  │    DOTNET_JWT_SECRET=<mesmo valor acima>"
echo "  └─────────────────────────────────────────────────────"

# ─── [4/5] Subir containers em background ────────────────────────────────────
echo ""
echo "[4/5] Subindo containers em modo background (obrigatório pela rubrica)..."
docker compose up -d --build

echo ""
echo "  Build em andamento — acompanhe com:"
echo "  docker compose logs -f"
echo ""
echo "  Oracle XE leva ~3-5 min para ficar healthy."
echo "  Java API e .NET aguardam Oracle automaticamente."

# ─── [5/5] Verificar status ──────────────────────────────────────────────────
echo ""
echo "[5/5] Status inicial dos containers..."
sleep 10
docker compose ps

VM_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "========================================================"
echo " SETUP CONCLUÍDO — aguarde Oracle ficar healthy (~5 min)"
echo "========================================================"
echo ""
echo "  Java API:   http://$VM_IP:8080/actuator/health"
echo "  .NET API:   http://$VM_IP:5000/swagger/index.html"
echo "  Oracle:     $VM_IP:1521"
echo ""
echo "  Acompanhar: docker compose logs -f"
echo "  Status:     docker compose ps"
echo "========================================================"
