#!/bin/bash
# =========================================================
# PULSO URBANO — Script de Evidencia para Video
# Execute apos os containers estarem UP: docker compose ps
# =========================================================

set -e
JAVA="pulso-java-562999"
DOTNET="pulso-dotnet-562999"
ORACLE="pulso-oracle-562999"
DB_USER="${ORACLE_APP_USER:-RM562999}"
DB_PASS="${ORACLE_APP_PASSWORD:-fiap2026}"

separator() { echo ""; echo "======================================"; echo "  $1"; echo "======================================"; }

# ── 1. Status dos containers ─────────────────────────────
separator "1. STATUS DOS CONTAINERS"
docker compose ps

# ── 2. Logs resumidos ────────────────────────────────────
separator "2. LOGS — JAVA API (ultimas 10 linhas)"
docker logs $JAVA --tail=10

separator "2. LOGS — .NET API (ultimas 10 linhas)"
docker logs $DOTNET --tail=10

# ── 3. Acesso ao terminal + whoami + ls ──────────────────
separator "3. JAVA API — whoami + estrutura"
docker container exec $JAVA whoami
docker container exec $JAVA pwd
docker container exec $JAVA ls -l /app

separator "3. .NET API — whoami + estrutura"
docker container exec $DOTNET whoami
docker container exec $DOTNET ls -l /app

separator "3. ORACLE — whoami"
docker container exec $ORACLE whoami

# ── 4. SELECT no banco (evidencia obrigatoria) ───────────
separator "4. SELECT NO BANCO — EVIDENCIA DE PERSISTENCIA"
docker container exec $ORACLE sqlplus -S $DB_USER/$DB_PASS@//localhost:1521/XEPDB1 << 'SQL'
SET LINESIZE 120
SET PAGESIZE 50

PROMPT === TABELAS DO SCHEMA ===
SELECT table_name FROM user_tables ORDER BY table_name;

PROMPT === CONTAGEM DE REGISTROS ===
SELECT 'USUARIO'           AS tabela, COUNT(*) AS total FROM usuario         UNION ALL
SELECT 'ZONA_CIDADE'       AS tabela, COUNT(*) AS total FROM zona_cidade      UNION ALL
SELECT 'LEITURA_SATELITE'  AS tabela, COUNT(*) AS total FROM leitura_satelite UNION ALL
SELECT 'SCORE_DIARIO'      AS tabela, COUNT(*) AS total FROM score_diario     UNION ALL
SELECT 'RECOMENDACAO'      AS tabela, COUNT(*) AS total FROM recomendacao;

PROMPT === SCORES RECENTES ===
SELECT id_score, id_zona, valor_score, classificacao, dt_score
FROM score_diario
ORDER BY dt_score DESC
FETCH FIRST 5 ROWS ONLY;

EXIT;
SQL

# ── 5. Teste dos endpoints ───────────────────────────────
separator "5. TESTE DE ENDPOINTS"
echo "Java API health:"
curl -s http://localhost:8080/actuator/health | head -c 200
echo ""
echo ".NET API health:"
curl -s http://localhost:5000/api/health | head -c 200

separator "EVIDENCIAS COLETADAS — GRAVACAO CONCLUIDA"
