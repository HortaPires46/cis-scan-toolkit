#!/usr/bin/env bash
#
# run-cis-scan.sh
# Executa scan de compliance CIS Server L1 (OpenSCAP) em RHEL 9
# sem causar OOM, usando a estrategia validada:
#   1. swap de seguranca (se ainda nao existir)
#   2. swappiness baixo (so usa swap em emergencia)
#   3. split do datastream SSG em componentes (XCCDF/OVAL/OCIL separados)
#   4. eval a partir do XCCDF ja separado (evita carregar o datastream
#      monolitico inteiro na memoria, que foi a causa raiz do OOM)
#
# Uso:
#   sudo ./run-cis-scan.sh /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
#
# Saida:
#   /root/cis-scan/<hostname>-<data>/resultado-cis.xml
#   /root/cis-scan/<hostname>-<data>/relatorio-cis-baseline.html
#
set -euo pipefail

# ---------- Config ----------
PROFILE="xccdf_org.ssgproject.content_profile_cis_server_l1"
SWAP_FILE="/swapfile"
SWAP_SIZE_GB=8
SWAPPINESS=10
OUT_BASE="/root/cis-scan"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_SHORT="$(hostname -s)"
OUT_DIR="${OUT_BASE}/${HOSTNAME_SHORT}-${TIMESTAMP}"
SPLIT_DIR="${OUT_DIR}/ssg-split"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERRO] $*" >&2; exit 1; }

# ---------- 0. Checagens iniciais ----------
[[ $EUID -eq 0 ]] || die "Precisa rodar como root (use sudo)."

DS_PATH="${1:-}"
[[ -n "$DS_PATH" ]] || die "Uso: $0 <caminho-do-datastream-ssg.xml>
Exemplo: $0 /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
[[ -f "$DS_PATH" ]] || die "Datastream nao encontrado em: $DS_PATH"

command -v oscap >/dev/null 2>&1 || die "oscap nao esta instalado neste servidor."

mkdir -p "$OUT_DIR"
log "Saida desta execucao: $OUT_DIR"

# ---------- 1. Swap de seguranca (idempotente) ----------
CURRENT_SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
if [[ "$CURRENT_SWAP_KB" -gt 0 ]]; then
    log "Swap ja configurado no sistema (total: $((CURRENT_SWAP_KB / 1024 / 1024)) GB). Pulando criacao."
else
    if [[ -f "$SWAP_FILE" ]]; then
        log "Arquivo $SWAP_FILE ja existe mas nao esta ativo. Ativando..."
        chmod 600 "$SWAP_FILE"
        swapon "$SWAP_FILE" || die "Falha ao ativar swap existente em $SWAP_FILE."
    else
        log "Criando swap de ${SWAP_SIZE_GB}GB em $SWAP_FILE..."
        fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_FILE" || die "Falha ao alocar swapfile."
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null
        swapon "$SWAP_FILE"
    fi

    if ! grep -qF "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        log "Entrada adicionada em /etc/fstab para persistir o swap."
    fi
fi

# ---------- 2. Swappiness (idempotente) ----------
CURRENT_SWAPPINESS="$(sysctl -n vm.swappiness)"
if [[ "$CURRENT_SWAPPINESS" -ne "$SWAPPINESS" ]]; then
    log "Ajustando vm.swappiness de $CURRENT_SWAPPINESS para $SWAPPINESS..."
    sysctl -w vm.swappiness="$SWAPPINESS" >/dev/null
    if grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^vm.swappiness.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf
    else
        echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
    fi
else
    log "vm.swappiness ja esta em $SWAPPINESS. Pulando."
fi

free -h | sed 's/^/    /'

# ---------- 3. Split do datastream ----------
log "Separando datastream em componentes (evita carregar o pacote inteiro no eval)..."
mkdir -p "$SPLIT_DIR"
oscap ds sds-split "$DS_PATH" "$SPLIT_DIR/" \
    || die "Falha ao executar sds-split. Verifique o caminho do datastream."

# Localiza o XCCDF gerado pelo split (o nome pode variar entre versoes do SSG)
XCCDF_FILE="$(find "$SPLIT_DIR" -maxdepth 1 -iname '*xccdf*.xml' | head -n1)"
[[ -n "$XCCDF_FILE" ]] || die "Nao encontrei nenhum arquivo XCCDF em $SPLIT_DIR apos o split."
XCCDF_BASENAME="$(basename "$XCCDF_FILE")"
log "XCCDF identificado: $XCCDF_BASENAME"

# Localiza o dicionario CPE gerado pelo split.
# CRITICO: sem isso, o oscap nao consegue confirmar a plataforma (RHEL 9) ao
# avaliar o XCCDF de forma standalone, e TODAS as regras retornam
# "notselected" silenciosamente (nenhum erro e exibido). Isso foi
# diagnosticado em campo: o eval terminava em <1 segundo e nao avaliava
# nenhuma regra de fato.
CPE_FILE="$(find "$SPLIT_DIR" -maxdepth 1 -iname '*cpe-dictionary*.xml' | head -n1)"
[[ -n "$CPE_FILE" ]] || die "Nao encontrei o dicionario CPE em $SPLIT_DIR apos o split."
CPE_BASENAME="$(basename "$CPE_FILE")"
log "Dicionario CPE identificado: $CPE_BASENAME"

# ---------- 4. Eval ----------
RESULTS_XML="${OUT_DIR}/resultado-cis.xml"

log "Iniciando avaliacao do perfil $PROFILE (pode levar bastante tempo, isso e normal)..."
set +e
( cd "$SPLIT_DIR" && oscap xccdf eval \
    --profile "$PROFILE" \
    --cpe "$CPE_BASENAME" \
    --results "$RESULTS_XML" \
    "$XCCDF_BASENAME" )
EVAL_RC=$?
set -e

# oscap retorna 2 quando ha falhas de compliance (esperado), 0 = tudo pass, 1 = erro real
if [[ $EVAL_RC -eq 1 ]]; then
    die "oscap retornou erro real (rc=1). Verifique os logs acima."
fi

[[ -s "$RESULTS_XML" ]] || die "Eval terminou mas $RESULTS_XML nao foi gerado ou esta vazio."

log "Avaliacao concluida (codigo de retorno do oscap: $EVAL_RC)."
log "  Resultados XML : $RESULTS_XML"

# ---------- 5. Relatorio HTML (opcional, melhor esforco) ----------
# A geracao do HTML pode falhar com "XPath error: growing nodeset hit limit"
# em servidores com grande volume de arquivos (limitacao conhecida do
# libxml2/OpenSCAP, ver README -> Riscos Conhecidos). Por isso e feita
# separadamente do eval, e uma falha aqui NAO derruba o script: o XML
# de resultados (que e o dado completo) ja foi salvo com sucesso acima.
REPORT_HTML="${OUT_DIR}/relatorio-cis-baseline.html"
log "Gerando relatorio HTML (melhor esforco; falha aqui nao e critica)..."
if oscap xccdf generate report --output "$REPORT_HTML" "$RESULTS_XML" 2>>"${OUT_DIR}/report-generation.log"; then
    log "  Relatorio HTML : $REPORT_HTML"
else
    log "  [AVISO] Falha ao gerar o HTML (provavelmente growing nodeset hit limit)."
    log "  [AVISO] O resultado em $RESULTS_XML permanece valido e completo."
    log "  [AVISO] Detalhes em ${OUT_DIR}/report-generation.log"
fi

# ---------- 6. Resumo rapido ----------
PASS_COUNT="$(grep -oE '<result>pass</result>' "$RESULTS_XML" | wc -l)"
FAIL_COUNT="$(grep -oE '<result>fail</result>' "$RESULTS_XML" | wc -l)"
NA_COUNT="$(grep -oE '<result>notapplicable</result>' "$RESULTS_XML" | wc -l)"
log "  Resumo rapido  : $PASS_COUNT pass / $FAIL_COUNT fail / $NA_COUNT notapplicable"
log "Concluido."
