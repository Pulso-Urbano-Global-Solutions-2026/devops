#!/usr/bin/env bash
# =============================================================================
# PULSO URBANO · deploy-azure.sh
# FIAP — DevOps Tools & Cloud Computing · Global Solution 2026/1
# RM 562999
#
# Provisiona a infraestrutura completa no Azure a partir do zero:
#   Resource Group → VM Ubuntu 22.04 → Docker Engine → Clone com submodulos
#   → Injeção do .env → docker compose up -d --build → Health check
#
# Pré-requisitos:
#   - Azure CLI autenticado (az login) ou Azure Cloud Shell
#   - Arquivo .env preenchido no diretório onde o script é executado
#
# Uso:
#   bash deploy-azure.sh
# =============================================================================
set -eu

# ─── HELPER: executa script remoto e valida conclusão ────────────────────────
# az vm run-command retorna exit 0 mesmo quando o script remoto falha.
# O sentinel STEP_OK impresso ao final garante detecção de falha real.
run_remote() {
    local DESCRICAO="$1"
    local SCRIPT="$2"

    echo "  >>> $DESCRICAO"

    local OUTPUT
    OUTPUT=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "$SCRIPT" \
        --output json 2>&1) || {
        echo "  ❌ Falha ao invocar comando remoto: $DESCRICAO"
        echo "$OUTPUT"
        exit 1
    }

    echo "$OUTPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('value', []):
        print(item.get('message', ''))
except Exception as e:
    print('(erro ao processar output:', e, ')')
" 2>/dev/null || echo "$OUTPUT"

    if ! echo "$OUTPUT" | grep -q "STEP_OK"; then
        echo ""
        echo "  ❌ Etapa falhou: $DESCRICAO"
        echo "  Script remoto nao confirmou conclusao — abortando."
        exit 1
    fi

    echo "  ✅ $DESCRICAO"
    echo ""
}

# ─── VALIDAÇÃO LOCAL ─────────────────────────────────────────────────────────
if [ ! -f ".env" ]; then
    echo "❌ Arquivo .env nao encontrado em $(pwd)"
    echo "   Crie o .env a partir do .env.example antes de continuar."
    exit 1
fi

ENV_B64=$(base64 -w 0 ".env")
echo "✅ .env carregado ($(wc -c < ".env") bytes)."

# ─── CONFIGURAÇÕES ────────────────────────────────────────────────────────────
RESOURCE_GROUP="pulso-rg-fiap2026"
LOCATION="centralus"
VM_NAME="pulso-vm-562999"
VM_SIZE="Standard_D2s_v3"    # 2 vCPU / 8 GB RAM
VM_IMAGE="Ubuntu2204"
ADMIN_USER="pulso-admin"
REPO_URL="https://github.com/Pulso-Urbano-Global-Solutions-2026/devops.git"
APP_DIR="/opt/pulso-urbano"
PORTS=(22 8080 5000 1521)

echo "========================================================"
echo " PULSO URBANO · Azure Deploy · GS 2026/1"
echo " VM: $VM_NAME · Regiao: $LOCATION"
echo "========================================================"

# ─── [1/8] Resource Group ────────────────────────────────────────────────────
echo ""
echo "[1/8] Criando Resource Group: $RESOURCE_GROUP..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table
echo "  ✅ Resource Group pronto."

# ─── [2/8] VM ────────────────────────────────────────────────────────────────
echo ""
echo "[2/8] Provisionando VM $VM_NAME ($VM_IMAGE · $VM_SIZE)..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --output table

VM_PUBLIC_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --show-details \
    --query "publicIps" \
    --output tsv)
echo "  ✅ VM criada. IP publico: $VM_PUBLIC_IP"

# ─── [3/8] Portas ────────────────────────────────────────────────────────────
echo ""
echo "[3/8] Abrindo portas: ${PORTS[*]}..."
PRIORITY=1010
for PORT in "${PORTS[@]}"; do
    echo "  → Porta $PORT..."
    az vm open-port \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --port "$PORT" \
        --priority "$PRIORITY" \
        --output none
    PRIORITY=$((PRIORITY + 10))
done
echo "  ✅ Portas abertas."

echo ""
echo "⏳ Aguardando VM estabilizar (60s)..."
sleep 60

# ─── [4/8] Docker Engine ─────────────────────────────────────────────────────
echo ""
echo "[4/8] Instalando Docker Engine..."
run_remote "Instalar Docker Engine" '#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git nano htop

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

docker --version
docker compose version
echo "STEP_OK"
'

# ─── [5/8] Usuário não-root no host ──────────────────────────────────────────
echo "[5/8] Criando usuario de servico (pulso-app)..."
run_remote "Criar usuario pulso-app" '#!/bin/bash
set -euo pipefail

if id pulso-app &>/dev/null; then
    echo "Usuario pulso-app ja existe."
else
    useradd --shell /bin/bash --create-home --home-dir /home/pulso-app pulso-app
fi

usermod -aG docker pulso-app
id pulso-app
echo "STEP_OK"
'

# ─── [6/8] Clone + .env ──────────────────────────────────────────────────────
echo "[6/8] Clonando repositorio e configurando ambiente..."
run_remote "Clone + injecao do .env" "#!/bin/bash
set -euo pipefail

mkdir -p $APP_DIR

if [ -d '$APP_DIR/.git' ]; then
    git -C $APP_DIR pull --recurse-submodules
    git -C $APP_DIR submodule update --init --recursive
else
    git clone --recurse-submodules $REPO_URL $APP_DIR
fi

echo '$ENV_B64' | base64 --decode > $APP_DIR/.env
chmod 600 $APP_DIR/.env
chown -R pulso-app:pulso-app $APP_DIR

ls -la $APP_DIR
echo 'STEP_OK'
"

# ─── [7/8] docker compose up ─────────────────────────────────────────────────
echo "[7/8] Subindo containers em background..."
echo "      Build inicial leva ~5-10 min (Maven + MSBuild + Oracle XE ~2 GB)."
run_remote "docker compose up -d --build" "#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/usr/local/bin:\$PATH

cd $APP_DIR
docker compose up --build -d
docker compose ps
echo 'STEP_OK'
"

# ─── [8/8] Health check ──────────────────────────────────────────────────────
echo "[8/8] Aguardando servicos ficarem disponiveis..."
echo "      Oracle XE leva ~3-5 min para registrar o XEPDB1."
echo "      Verificando a cada 30s por ate 15 min..."
echo ""

JAVA_OK=false
DOTNET_OK=false

for i in $(seq 1 30); do
    echo "  ⏳ Verificacao $i/30..."
    sleep 30

    CONTAINER_STATUS=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "#!/bin/bash
export PATH=/usr/bin:/usr/local/bin:\$PATH
cd $APP_DIR 2>/dev/null && docker compose ps 2>/dev/null || echo 'aguardando...'
" --output json 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('value', []):
        print(item.get('message', ''))
except:
    pass
" 2>/dev/null || echo "  (consultando VM...)")

    echo "$CONTAINER_STATUS"

    JAVA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
        "http://$VM_PUBLIC_IP:8080/actuator/health" 2>/dev/null || echo "000")
    DOTNET_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
        "http://$VM_PUBLIC_IP:5000/swagger/index.html" 2>/dev/null || echo "000")

    echo "  ├── Java API  :8080 → HTTP $JAVA_HTTP"
    echo "  └── .NET API  :5000 → HTTP $DOTNET_HTTP"
    echo ""

    [ "$JAVA_HTTP"  = "200" ] && JAVA_OK=true
    [ "$DOTNET_HTTP" = "200" ] && DOTNET_OK=true

    if $JAVA_OK && $DOTNET_OK; then
        echo "  ✅ Stack operacional!"
        break
    fi
done

# ─── SUMÁRIO ─────────────────────────────────────────────────────────────────
echo "========================================================"
echo " DEPLOY CONCLUIDO — PULSO URBANO"
echo "========================================================"
echo ""
echo "  VM:     $VM_NAME"
echo "  IP:     $VM_PUBLIC_IP"
echo "  Regiao: $LOCATION"
echo ""
echo "  ┌── Endpoints ────────────────────────────────────────"
echo "  │  Java API:  http://$VM_PUBLIC_IP:8080/actuator/health"
echo "  │  Swagger:   http://$VM_PUBLIC_IP:8080/swagger-ui.html"
echo "  │  .NET API:  http://$VM_PUBLIC_IP:5000/swagger/index.html"
echo "  │  Oracle:    $VM_PUBLIC_IP:1521 (XEPDB1 / RM562999)"
echo "  └──────────────────────────────────────────────────────"
echo ""
echo "  ┌── Acesso ───────────────────────────────────────────"
echo "  │  SSH:    ssh $ADMIN_USER@$VM_PUBLIC_IP"
echo "  │  Logs:   ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs -f'"
echo "  │  Status: ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose ps'"
echo "  └──────────────────────────────────────────────────────"
echo ""

if ! $JAVA_OK; then
    echo "  ⚠️  Java API nao respondeu. Logs:"
    echo "  ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs java-api --tail=50'"
    echo ""
fi
if ! $DOTNET_OK; then
    echo "  ⚠️  .NET API nao respondeu. Logs:"
    echo "  ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs dotnet-api --tail=50'"
    echo ""
fi

echo "  Cleanup pos-avaliacao:"
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "========================================================"
