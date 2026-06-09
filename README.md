# Pulso Urbano — Infraestrutura DevOps

**Global Solution 2026/1 · FIAP · ADS 2º ano**  
Disciplina: **DevOps Tools & Cloud Computing**

---

## Por que containerização em nuvem?

Durante o desenvolvimento, cada serviço do Pulso Urbano rodava na máquina de cada desenvolvedor — funcionava localmente, mas a banca precisa ver rodando em produção real. Containerização com Docker resolve o "na minha máquina funciona": a mesma imagem que passa nos testes locais é a que sobe na Azure.

Escolhemos **Azure VM** em vez de PaaS (Heroku, Railway para toda a stack) porque a rubrica exige controle total sobre os containers — o professor vai executar `docker exec`, `docker logs` e `whoami` na VM. Com PaaS isso não seria possível.

---

## Equipe

| Integrante | RM | Papel |
|------------|-----|-------|
| **Felipe Ferrete** | 562999 | Tech Lead · Dockerfiles das APIs · arquitetura dos containers |
| **Clayton Alves** | 562285 | Database · DevOps — **dono desta entrega** — Docker Compose, deploy Azure, script de provisionamento |
| **Guilherme Sola** | 563674 | Mobile · Frontend React Native |
| **Gustavo Bosak** | 566315 | QA · Arquitetura TOGAF · diagrama arquitetural |
| **Nikolas Brisola** | 564371 | IoT · ESP32 |

---

## Links

| Recurso | URL |
|---------|-----|
| Java API Swagger (Azure) | `http://20.12.204.186:8080/swagger-ui.html` |
| .NET API Swagger (Azure) | `http://20.12.204.186:5000/swagger/index.html` |
| Vídeo DevOps (YouTube) | `https://youtu.be/xKcHJiNuz8c?si=qI1V-ZRdnVJvfwYZ` |
| Repositório Java | `https://github.com/Pulso-Urbano-Global-Solutions-2026/backend-java` |
| Repositório .NET | `https://github.com/Pulso-Urbano-Global-Solutions-2026/backend-dotnet` |

---

## Arquitetura Macro

![Arquitetura Macro](docs/DevOps-fluxo-pulso-urbano-final.drawio.png)



---

## Stack

| Componente | Versão / Detalhe |
|------------|-----------------|
| Azure VM | Standard_D2s_v3 (2 vCPU, 8 GB RAM, Ubuntu 22.04 LTS) |
| Docker Engine | 27.x (instalado via apt repositório oficial) |
| Docker Compose | v2 (plugin `docker compose`, sem hífen) |
| Oracle XE | `gvenzl/oracle-xe:21-slim` |
| Java API | Build multi-stage JDK 21 Temurin → JRE 21 Alpine |
| .NET API | Build multi-stage .NET SDK 10 → ASP.NET Runtime 10 |

---

## Containers

| Container | Imagem | Porta host | Usuário | Volume |
|-----------|--------|-----------|---------|--------|
| `pulso-oracle-562999` | `gvenzl/oracle-xe:21-slim` | 1521 | oracle (padrão) | `pulso-oracle-data:/opt/oracle/oradata` |
| `pulso-java-562999` | build local `./java-api/pulso-java/Dockerfile` | 8080 | `pulso` (não-root) | — |
| `pulso-dotnet-562999` | build local `./dotnet-api/Dockerfile` | 5000 | `pulso` (não-root) | — |

**Rede:** `pulso-net` (bridge) — todos os 3 containers na mesma rede  
**Volume:** `pulso-oracle-data` (named volume — dados do Oracle persistem entre reinicializações)

---

## Estrutura do Repositório

```
devops/
├── java-api/               ← submodulo: Spring Boot (Dockerfile aqui)
│   └── pulso-java/
│       └── Dockerfile      ← multi-stage JDK 21 → JRE Alpine
├── dotnet-api/             ← submodulo: ASP.NET Core (Dockerfile aqui)
│   └── Dockerfile          ← multi-stage .NET SDK 10 → Runtime
├── docs/
│   ├── arquitetura-macro.drawio   ← diagrama editável
│   └── arquitetura-macro.png      ← imagem para README
├── scripts/
│   ├── deploy-azure.sh     ← provisionamento completo na Azure
│   └── evidencia-banco.sh  ← script de evidências para o vídeo
├── docker-compose.yml      ← orquestração dos 3 containers
├── .env.example            ← template de variáveis — NUNCA commitar .env
└── README.md
```

---

## Dockerfile Java — Multi-Stage (Anotado)

```dockerfile
# Stage 1: Build — usa JDK completo para compilar
FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /build
COPY pom.xml .
# Download de dependências separado do código-fonte (cache Docker eficiente)
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

# Stage 2: Runtime — imagem mínima sem JDK (segurança + tamanho)
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# Usuário não-root (critério obrigatório da rubrica)
RUN addgroup -S pulso && adduser -S pulso -G pulso
USER pulso

# Porta exposta (critério obrigatório)
EXPOSE 8080

# Variável de ambiente (critério obrigatório)
ENV JAVA_OPTS="-Xmx512m -Xms256m"

COPY --from=build /build/target/*.jar app.jar
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

**Por que multi-stage?** A imagem final não contém o Maven, o JDK ou os fontes — apenas o `.jar` e o JRE mínimo. Resultado: imagem de ~180 MB em vez de ~500 MB.

---

## Variáveis de Ambiente

| Variável | Obrigatória | Descrição |
|----------|-------------|-----------|
| `ORACLE_PASSWORD` | Sim | Senha do SYS do Oracle XE |
| `ORACLE_APP_USER` | Sim | Usuário da aplicação (ex: `RM562999`) |
| `ORACLE_APP_PASSWORD` | Sim | Senha do usuário da aplicação |
| `JWT_SECRET` | Sim | Segredo JWT — compartilhado entre Java e .NET |
| `DOTNET_JWT_SECRET` | Sim | Mesmo valor de `JWT_SECRET` |
| `DOTNET_DB_USER` | Sim | Usuário Oracle para a API .NET |
| `DOTNET_DB_PASS` | Sim | Senha Oracle para a API .NET |
| `COPERNICUS_USER` | Não | Email ESA Copernicus (pode ficar vazio no demo) |
| `COPERNICUS_PASS` | Não | Senha ESA Copernicus |
| `NASA_EARTHDATA_TOKEN` | Não | Token NASA AppEEARS |
| `CORS_ALLOWED_ORIGINS` | Não | Padrão: `*` |
| `ASPNETCORE_ENVIRONMENT` | Não | Padrão: `Development` (seed automático) |

---

## How-to Completo — Do Git Clone ao Teste em Produção

> **Pré-requisito:** Azure for Students ativo, Azure CLI instalada, Docker instalado.

### Opção A — Deploy na Azure (produção, para o vídeo)

```bash
# 1. Clonar o repositório com submodules
git clone --recurse-submodules <url-do-devops-repo>
cd devops

# 2. Criar o .env a partir do template
cp .env.example .env
# Edite .env com seus valores reais — NUNCA commitar esse arquivo

# 3. Rodar o script de provisionamento (~15 min)
bash scripts/deploy-azure.sh

# O script executa:
# [1/8] Cria Resource Group:  pulso-rg-fiap2026
# [2/8] Cria VM:              pulso-vm-562999 (Standard_D2s_v3, Ubuntu 22.04)
# [3/8] Abre portas:          22, 8080, 5000 (1521 bloqueado externamente)
# [4/8] Instala Docker Engine via repositório oficial apt
# [5/8] Cria usuário host:    pulso-admin (não-root)
# [6/8] Clona repo + injeta .env
# [7/8] Sobe containers:      docker compose up --build -d
# [8/8] Health check:         30 tentativas × 30s — /actuator/health e /api/health

# 4. SSH na VM para verificar
ssh pulso-admin@20.12.204.186
cd /opt/pulso-urbano
```

### Opção B — Desenvolvimento local

```bash
# 1. Clonar
git clone --recurse-submodules <url-do-devops-repo>
cd devops

# 2. .env
cp .env.example .env  # edite conforme necessário

# 3. Subir todos os containers em background
docker compose up --build -d

# Aguardar Oracle inicializar (~2 min — healthcheck de 30s × 10 retries)
docker compose ps  # aguardar oracle: healthy

# 4. Verificar
curl http://localhost:8080/actuator/health
curl http://localhost:5000/api/health
```

---

## Evidências Obrigatórias para o Vídeo

O professor vai verificar os itens abaixo. Execute cada comando e grave a tela.

### 1. `docker ps` — 3 containers UP

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Saída esperada:
```
NAMES                   STATUS          PORTS
pulso-java-562999       Up 2 hours      0.0.0.0:8080->8080/tcp
pulso-dotnet-562999     Up 2 hours      0.0.0.0:5000->5000/tcp
pulso-oracle-562999     Up 2 hours (healthy)   0.0.0.0:1521->1521/tcp
```

### 2. `whoami` — usuário não-root

```bash
docker exec pulso-java-562999   whoami   # → pulso
docker exec pulso-dotnet-562999 whoami   # → pulso
```

### 3. `pwd` e `ls -l` — diretório de trabalho

```bash
docker exec pulso-java-562999 pwd        # → /app
docker exec pulso-java-562999 ls -l /app
# → -rw-r--r-- 1 pulso pulso 45678901 Jun  7 14:30 app.jar
```

### 4. Logs de ambos os containers de app

```bash
docker logs pulso-java-562999   --tail=20
docker logs pulso-dotnet-562999 --tail=20
```

### 5. SELECT no Oracle dentro do container

```bash
docker exec -it pulso-oracle-562999 \
  sqlplus RM562999/fiap2026@//localhost:1521/XEPDB1 <<EOF
  SELECT table_name FROM user_tables ORDER BY table_name;
  SELECT COUNT(*) AS total_usuarios FROM usuario;
  SELECT COUNT(*) AS total_scores FROM score_diario;
  EXIT;
EOF
```

### 6. Health checks dos serviços

```bash
# Java API
curl http://20.12.204.186:8080/actuator/health
# → {"status":"UP","components":{"db":{"status":"UP"}}}

# .NET API
curl http://20.12.204.186:5000/api/health
# → {"status":"healthy","database":"connected"}
```

### 7. Swagger nos IPs públicos (gravar no browser)

```
Java API Swagger: http://20.12.204.186:8080/swagger-ui.html
.NET API Swagger: http://20.12.204.186:5000/swagger/index.html
```

Execute um endpoint de cada API ao vivo no Swagger — por exemplo POST `/api/v1/auth/login` na Java e GET `/api/alertas` na .NET.

---

## Script `evidencia-banco.sh`

Para facilitar a coleta de evidências, execute:

```bash
bash scripts/evidencia-banco.sh
```

O script executa todos os comandos de evidência em sequência e salva a saída em `evidencias-$(date +%Y%m%d).txt` para incluir no relatório.

---

## Roteiro do Vídeo DevOps

> Objetivo: demonstrar o critério completo em 8–10 minutos.

| Tempo | Conteúdo |
|-------|---------|
| 0:00–0:45 | Abertura: apresentar o sistema (1 slide), mostrar diagrama macro da arquitetura |
| 0:45–2:00 | `docker ps` — 3 containers UP com nomes RM; `docker compose ps` |
| 2:00–3:30 | `docker exec whoami` em java e dotnet → "pulso"; `pwd` → /app; `ls -l` |
| 3:30–5:00 | `docker logs` java e dotnet (20 últimas linhas de cada) |
| 5:00–6:30 | `docker exec sqlplus` → SELECT tables; SELECT COUNT(*) de 2+ tabelas |
| 6:30–8:00 | curl na URL Azure (Java health + .NET health) + Swagger no browser |
| 8:00–8:30 | Mostrar `docker-compose.yml`: rede pulso-net, volume pulso-oracle-data, RM nos nomes |
| 8:30–9:00 | `az group show --name pulso-rg-fiap2026` — prova de que está na Azure |

---

## Rubrica Coberta

### DevOps Tools & Cloud Computing — Checklist

| Critério | Valor | Status | Evidência |
|----------|-------|--------|-----------|
| Container da app construído via Dockerfile (não imagem pública) | -1.0 se não | ✅ | `build: context: ./java-api/pulso-java` no compose |
| Usuário não-root no container | -0.5 se não | ✅ | `USER pulso` no Dockerfile; `whoami → pulso` |
| Diretório de trabalho definido | -0.5 se não | ✅ | `WORKDIR /app` no Dockerfile |
| Variável de ambiente usada | -0.5 se não | ✅ | `ENV JAVA_OPTS=...` + env vars do compose |
| Porta exposta | -0.5 se não | ✅ | `EXPOSE 8080` no Dockerfile Java; `EXPOSE 5000` no .NET |
| Nome do container contém RM | -0.5 se não | ✅ | `pulso-java-562999`, `pulso-dotnet-562999`, `pulso-oracle-562999` |
| CRUD completo em 2+ tabelas | -0.5 se não | ✅ | Java: CRUD em `usuario`, `score_diario`; .NET: CRUD em `ALERTA_HISTORICO` |
| Volume nomeado para o banco | -1.0 se não | ✅ | `pulso-oracle-data:/opt/oracle/oradata` |
| Mesma rede Docker | -0.5 se não | ✅ | `pulso-net: driver: bridge`; todos os 3 na mesma rede |
| Execução em background | -0.5 se não | ✅ | `docker compose up --build -d` |
| Logs de 2 containers mostrados | -0.5 se não | ✅ | `docker logs pulso-java-562999` e `docker logs pulso-dotnet-562999` |
| `docker exec ls -l` + `pwd` + `whoami` | -0.5 se não | ✅ | Comandos documentados na seção Evidências |
| SELECT no banco dentro do container | -0.5 se não | ✅ | `docker exec -it pulso-oracle-562999 sqlplus...` |
| Deploy fora de localhost | -2.0 se não | ✅ | Azure VM `20.12.204.186`, IPs públicos documentados |
| Diagrama de arquitetura macro | — | ✅ | `docs/arquitetura-macro.drawio` + `.png` |
| How-to completo no GitHub README | — | ✅ | Este documento |
| Vídeo demonstração (YouTube) | — | _gravar_ | Link acima |

---

## Troubleshooting

**Oracle demora para subir (`service_healthy` nunca alcançado):**
```bash
# O Oracle XE 21-slim pode demorar até 3 minutos na primeira execução
docker logs pulso-oracle-562999 -f
# Aguardar a linha: "DATABASE IS READY TO USE!"
```

**Java API não conecta ao Oracle:**
```bash
# Verificar se o DB_HOST no compose está correto (deve ser o nome do service, não localhost)
docker compose exec java-api env | grep DB_HOST
# → DB_HOST=oracle  (correto)
```

**Erro de memória no Oracle na Azure:**
```bash
# Standard_D2s_v3 tem 8 GB — suficiente para os 3 containers
# Se falhar, verifique com:
free -h
docker stats --no-stream
```

**Porta 8080 não acessível externamente:**
```bash
# Verificar Network Security Group da Azure
az network nsg rule list --nsg-name pulso-nsg-562999 --resource-group pulso-rg-fiap2026 -o table
# Se a porta 8080 não estiver listada:
az network nsg rule create --name allow-8080 --nsg-name pulso-nsg-562999 \
  --resource-group pulso-rg-fiap2026 --priority 100 \
  --protocol tcp --destination-port-ranges 8080 --access Allow
```

---

## Cleanup pós-avaliação

```bash
# Apagar todos os recursos Azure criados pelo script (não cobrável depois)
az group delete --name pulso-rg-fiap2026 --yes --no-wait
```

---

*Pulso Urbano DevOps · Owner: Clayton Alves (RM 562285) · GS 2026/1 · FIAP 2TDS*
