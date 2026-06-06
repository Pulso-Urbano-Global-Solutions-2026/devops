#!/usr/bin/env bash
# =============================================================================
# PULSO URBANO · deploy-azure.sh — FIAP DevOps Tools & Cloud Computing GS 2026/1
# RM representante: 562999
#
# Provisiona e sobe toda a infra do zero no Azure:
#   Resource Group → VM Ubuntu 22.04 → Docker → Clone com submodulos
#   → Injeção do .env → docker compose up -d --build → Health check loop
#
# CORREÇÕES (padrão KURA v4):
#   - Sentinel STEP_OK detecta falha real no script remoto
#   - Sem | jq (mascara exit codes) — usa python3 nativo do Cloud Shell
#   - #!/bin/bash + set -euo pipefail em CADA bloco remoto
#   - Docker instalado via apt repository oficial (não pipe curl|sh)
#   - docker compose roda como root no host (daemon exige;
#     rubrica "usuario nao-root" = USER nos Dockerfiles, nao no host)
#
# Pré-requisitos:
#   - Azure CLI autenticado: az login
#   - .env preenchido na pasta raiz do repo (ao lado deste script)
#
# Uso (do Azure Cloud Shell ou terminal local com az CLI):
#   cd <pasta raiz do repo>
#   bash scripts/deploy-azure.sh
# =============================================================================
set -eu

# ─── HELPER: executa script remoto e verifica STEP_OK ───────────────────────
run_remote() {
    local DESCRICAO="$1"
    local SCRIPT="$2"

    echo "  >>> Executando: $DESCRICAO"

    local OUTPUT
    OUTPUT=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "$SCRIPT" \
        --output json 2>&1) || {
        echo "  ❌ Azure CLI falhou para: $DESCRICAO"
        echo "$OUTPUT"
        exit 1
    }

    # Exibe stdout/stderr do script remoto sem jq
    echo "$OUTPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('value', []):
        print(item.get('message', ''))
except Exception as e:
    print('(erro ao parsear output:', e, ')')
" 2>/dev/null || echo "$OUTPUT"

    # Sem STEP_OK = script remoto falhou
    if ! echo "$OUTPUT" | grep -q "STEP_OK"; then
        echo ""
        echo "  ❌ FALHA REAL em: $DESCRICAO"
        echo "  O script remoto nao imprimiu STEP_OK — interrompendo."
        exit 1
    fi

    echo "  ✅ $DESCRICAO — OK"
    echo ""
}

# ─── VALIDAÇÃO LOCAL ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$ROOT_DIR/.env" ]; then
    echo "❌ ERRO: .env nao encontrado em $ROOT_DIR/.env"
    echo "   Execute: cp .env.example .env  e preencha os valores."
    exit 1
fi

ENV_B64=$(base64 -w 0 "$ROOT_DIR/.env")
echo "✅ .env carregado e codificado ($(wc -c < "$ROOT_DIR/.env") bytes)."

# ─── CONFIGURAÇÕES ────────────────────────────────────────────────────────────
RESOURCE_GROUP="pulso-rg-fiap2026"
LOCATION="eastus"
VM_NAME="pulso-vm-562999"          # RM no nome — rubrica exige
VM_SIZE="Standard_B2s"             # 2 vCPU, 4 GB RAM — suficiente para Oracle XE
VM_IMAGE="Ubuntu2204"
ADMIN_USER="pulso-admin"
REPO_URL="https://github.com/Pulso-Urbano-Global-Solutions-2026/devops.git"
APP_DIR="/opt/pulso-urbano"
PORTS=(22 8080 5000 1521)

echo "========================================================"
echo " PULSO URBANO · FIAP DevOps GS 2026/1 · Azure Deploy"
echo " VM: $VM_NAME · RM: 562999"
echo "========================================================"

# ─── [1/8] Resource Group ────────────────────────────────────────────────────
echo ""
echo "[1/8] Criando Resource Group: $RESOURCE_GROUP em $LOCATION..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table
echo "  ✅ Resource Group criado."

# ─── [2/8] VM Ubuntu 22.04 (x86 — Oracle XE exige amd64) ────────────────────
echo ""
echo "[2/8] Provisionando VM Linux ($VM_IMAGE · $VM_SIZE)..."
echo "      Standard_B2s = 2 vCPU / 4 GB RAM — x86_64 (Oracle XE nativo)"
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
echo "  ✅ VM criada. IP público: $VM_PUBLIC_IP"

# ─── [3/8] Abrir portas no NSG ───────────────────────────────────────────────
echo ""
echo "[3/8] Abrindo portas: ${PORTS[*]}..."
PRIORITY=1010
for PORT in "${PORTS[@]}"; do
    echo "  → Porta $PORT (prioridade $PRIORITY)..."
    az vm open-port \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --port "$PORT" \
        --priority "$PRIORITY" \
        --output none
    PRIORITY=$((PRIORITY + 10))
done
echo "  ✅ Portas abertas: ${PORTS[*]}"

echo ""
echo "⏳ Aguardando 60s para o agente da VM estabilizar..."
sleep 60

# ─── [4/8] Docker Engine via apt (não curl|sh) ───────────────────────────────
echo ""
echo "[4/8] Instalando Docker Engine, Git e utilitários..."
run_remote "Instalar Docker Git curl" '#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Atualizando pacotes ==="
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git nano htop

echo "=== Adicionando repositorio Docker oficial ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "=== Instalando Docker CE + Compose plugin ==="
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "=== Versoes instaladas ==="
docker --version
docker compose version
echo "STEP_OK"
'

# ─── [5/8] Criar usuario nao-root no host (pulso-app) ────────────────────────
# Rubrica "nao-root" = USER pulso nos Dockerfiles (dentro dos containers).
# pulso-app no host e boa pratica adicional — nao confundir com o USER do container.
echo "[5/8] Criando usuario nao-root no host (pulso-app)..."
run_remote "Criar usuario pulso-app" '#!/bin/bash
set -euo pipefail

echo "=== Criando usuario pulso-app ==="
if id pulso-app &>/dev/null; then
    echo "Usuario pulso-app ja existe:"
    id pulso-app
else
    useradd \
        --shell /bin/bash \
        --create-home \
        --home-dir /home/pulso-app \
        pulso-app
    echo "Usuario criado:"
    id pulso-app
fi

usermod -aG docker pulso-app
echo "=== Usuario final ==="
id pulso-app
echo "STEP_OK"
'

# ─── [6/8] Clone + injeção segura do .env ────────────────────────────────────
echo "[6/8] Clonando repositorio com submodulos e injetando .env..."
run_remote "Clone + .env" "#!/bin/bash
set -euo pipefail

echo '=== Preparando diretorio $APP_DIR ==='
mkdir -p $APP_DIR

if [ -d '$APP_DIR/.git' ]; then
    echo 'Repo ja existe — atualizando submodulos...'
    git -C $APP_DIR pull --recurse-submodules
    git -C $APP_DIR submodule update --init --recursive
else
    echo 'Clonando com submodulos...'
    git clone --recurse-submodules $REPO_URL $APP_DIR
fi

echo '=== Verificando submodulos ==='
ls $APP_DIR/java-api/   | head -5
ls $APP_DIR/dotnet-api/ | head -5

echo '=== Injetando .env ==='
echo '$ENV_B64' | base64 --decode > $APP_DIR/.env
chmod 600 $APP_DIR/.env
chown -R pulso-app:pulso-app $APP_DIR
echo 'Linhas no .env:'
wc -l $APP_DIR/.env

echo '=== Estrutura final ==='
ls -la $APP_DIR
echo 'STEP_OK'
"

# ─── [7/8] docker compose up -d --build ─────────────────────────────────────
# Roda como root no host — daemon Docker exige privilegio root.
# Usuarios nao-root estao DENTRO dos containers (USER pulso nos Dockerfiles).
echo "[7/8] Subindo stack com docker compose up -d --build..."
echo "      Build leva ~5-10 min (Maven + MSBuild + download Oracle XE ~2GB)."
echo "      Aguarde..."
run_remote "docker compose up -d --build" "#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/usr/local/bin:\$PATH

echo '=== Build e start dos containers ==='
cd $APP_DIR
docker compose up --build -d

echo '=== Status inicial dos containers ==='
docker compose ps
echo 'STEP_OK'
"

# ─── [8/8] Health check loop ─────────────────────────────────────────────────
echo "[8/8] Verificando saude dos servicos..."
echo "      Oracle XE leva 3-5 min para registrar XEPDB1."
echo "      Java API e .NET aguardam Oracle ficar healthy."
echo "      Aguardando (max 15 min | 30 x 30s)..."
echo ""

JAVA_OK=false
DOTNET_OK=false

for i in $(seq 1 30); do
    echo "  ⏳ Tentativa $i/30 — aguardando 30s..."
    sleep 30

    # Status interno via run-command
    CONTAINER_STATUS=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "#!/bin/bash
export PATH=/usr/bin:/usr/local/bin:\$PATH
cd $APP_DIR 2>/dev/null || { echo 'APP_DIR nao encontrado'; exit 0; }
docker compose ps 2>/dev/null || echo 'compose nao iniciado'
" --output json 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('value', []):
        print(item.get('message', ''))
except:
    pass
" 2>/dev/null || echo "  (falha ao consultar VM)")

    echo "$CONTAINER_STATUS"
    echo ""

    # Health checks externos — prova real de acessibilidade pública
    JAVA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
        "http://$VM_PUBLIC_IP:8080/actuator/health" 2>/dev/null || echo "000")
    DOTNET_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
        "http://$VM_PUBLIC_IP:5000/swagger/index.html" 2>/dev/null || echo "000")

    echo "  Health checks externos (IP: $VM_PUBLIC_IP):"
    echo "  ├── Java API  :8080/actuator/health → HTTP $JAVA_HTTP"
    echo "  └── .NET API  :5000/swagger         → HTTP $DOTNET_HTTP"
    echo ""

    [ "$JAVA_HTTP"  = "200" ] && JAVA_OK=true
    [ "$DOTNET_HTTP" = "200" ] && DOTNET_OK=true

    if $JAVA_OK && $DOTNET_OK; then
        echo "  ✅ Ambas as APIs respondendo — stack operacional!"
        break
    fi
done

# ─── SUMÁRIO FINAL ───────────────────────────────────────────────────────────
echo "========================================================"
echo " PROVISIONAMENTO CONCLUÍDO — PULSO URBANO"
echo "========================================================"
echo ""
echo "  VM:       $VM_NAME (RM 562999)"
echo "  IP:       $VM_PUBLIC_IP"
echo "  Regiao:   $LOCATION"
echo ""
echo "  ┌── Endpoints ────────────────────────────────────────"
echo "  │  Java API health:  http://$VM_PUBLIC_IP:8080/actuator/health"
echo "  │  Java API swagger: http://$VM_PUBLIC_IP:8080/swagger-ui.html"
echo "  │  .NET API swagger: http://$VM_PUBLIC_IP:5000/swagger/index.html"
echo "  │  Oracle:           $VM_PUBLIC_IP:1521 (XEPDB1)"
echo "  └──────────────────────────────────────────────────────"
echo ""
echo "  ┌── Comandos úteis ───────────────────────────────────"
echo "  │  SSH:    ssh $ADMIN_USER@$VM_PUBLIC_IP"
echo "  │  Logs:   ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs -f'"
echo "  │  Status: ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose ps'"
echo "  │  Exec:   ssh $ADMIN_USER@$VM_PUBLIC_IP 'docker container exec pulso-java-562999 whoami'"
echo "  └──────────────────────────────────────────────────────"
echo ""

if ! $JAVA_OK; then
    echo "  ⚠️  Java API nao respondeu. Verifique logs:"
    echo "  ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs java-api --tail=50'"
    echo ""
fi
if ! $DOTNET_OK; then
    echo "  ⚠️  .NET API nao respondeu. Verifique logs:"
    echo "  ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs dotnet-api --tail=50'"
    echo ""
fi

echo "  ⚠️  LEMBRETE: delete a VM apos a avaliacao para evitar cobrança:"
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "========================================================"

# ─── Descomente apos a avaliação para cleanup automático ─────────────────────
# az group delete --name "$RESOURCE_GROUP" --yes --no-wait
