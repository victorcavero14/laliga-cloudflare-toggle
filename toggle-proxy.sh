#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# toggle-proxy.sh
# Deshabilita/rehabilita el proxy CDN de Cloudflare automaticamente segun
# los bloqueos de LaLiga detectados por hayahora.futbol
#
# Disenado para ser crash-safe e idempotente:
# - State file se escribe incrementalmente (tras cada PATCH)
# - Lock file previene ejecuciones concurrentes
# - Re-ejecucion tras crash retoma donde se quedo
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Cargar configuracion ---------------------------------------------------

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# --- Valores por defecto ----------------------------------------------------

LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/toggle-proxy.log}"
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/state/proxy_disabled.json}"
LOCK_FILE="${SCRIPT_DIR}/state/toggle-proxy.lock"
DRY_RUN="${DRY_RUN:-false}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
HAYAHORA_API="https://hayahora.futbol/estado/data.json"
CF_API_BASE="https://api.cloudflare.com/client/v4"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

# --- Funciones auxiliares ----------------------------------------------------

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

notify_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s --max-time 10 \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d parse_mode="HTML" \
            -d text="$message" >/dev/null 2>&1 || {
            log "WARN" "No se pudo enviar notificacion de Telegram"
        }
    fi
}

# Comprobar si una IP pertenece a los rangos de Cloudflare
# Usa los rangos publicados en cloudflare.com/ips
is_cloudflare_ip() {
    local ip="$1"

    # IPv6: comprobar prefijos conocidos de Cloudflare
    if [[ "$ip" == *:* ]]; then
        local cf6_prefixes="2400:cb00 2606:4700 2803:f800 2405:b500 2405:8100 2a06:98c 2c0f:f248"
        for prefix in $cf6_prefixes; do
            [[ "$ip" == ${prefix}* ]] && return 0
        done
        return 1
    fi

    # IPv4: extraer primer y segundo octeto y comprobar contra rangos CIDR conocidos
    local oct1 oct2 oct3
    IFS='.' read -r oct1 oct2 oct3 _ <<< "$ip"

    # Rangos Cloudflare IPv4 (de cloudflare.com/ips-v4):
    # 103.21.244.0/22, 103.22.200.0/22, 103.31.4.0/22
    # 104.16.0.0/13 (104.16-23.x.x), 104.24.0.0/14 (104.24-27.x.x)
    # 108.162.192.0/18
    # 131.0.72.0/22
    # 141.101.64.0/18
    # 162.158.0.0/15 (162.158-159.x.x)
    # 172.64.0.0/13 (172.64-71.x.x)
    # 173.245.48.0/20
    # 188.114.96.0/20 (188.114.96-111.x.x)
    # 190.93.240.0/20
    # 197.234.240.0/22
    # 198.41.128.0/17 (198.41.128-255.x.x)
    case "$oct1" in
        103) [[ "$oct2" -eq 21 || "$oct2" -eq 22 || "$oct2" -eq 31 ]] && return 0 ;;
        104) [[ "$oct2" -ge 16 && "$oct2" -le 27 ]] && return 0 ;;
        108) [[ "$oct2" -eq 162 ]] && return 0 ;;
        131) [[ "$oct2" -eq 0 && "$oct3" -ge 72 && "$oct3" -le 75 ]] && return 0 ;;
        141) [[ "$oct2" -eq 101 ]] && return 0 ;;
        162) [[ "$oct2" -ge 158 && "$oct2" -le 159 ]] && return 0 ;;
        172) [[ "$oct2" -ge 64 && "$oct2" -le 71 ]] && return 0 ;;
        173) [[ "$oct2" -eq 245 ]] && return 0 ;;
        188) [[ "$oct2" -eq 114 && "$oct3" -ge 96 && "$oct3" -le 111 ]] && return 0 ;;
        190) [[ "$oct2" -eq 93 ]] && return 0 ;;
        197) [[ "$oct2" -eq 234 ]] && return 0 ;;
        198) [[ "$oct2" -eq 41 && "$oct3" -ge 128 ]] && return 0 ;;
    esac
    return 1
}

# Escritura atomica: escribe a tmp y luego mv (previene corrupcion por crash)
atomic_write() {
    local file="$1"
    local content="$2"
    echo "$content" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Leer state file de forma segura (devuelve [] si no existe o esta corrupto)
read_state() {
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        jq '.' "$STATE_FILE" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
}

# --- Lock file (prevenir ejecucion concurrente) -----------------------------

if [[ -f "$LOCK_FILE" ]]; then
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        log "WARN" "Otra instancia en ejecucion (PID $lock_pid). Saliendo."
        exit 0
    else
        log "WARN" "Lock file huerfano encontrado (PID $lock_pid ya no existe). Limpiando."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT

# --- Verificar dependencias -------------------------------------------------

for cmd in curl jq dig; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR" "Comando requerido '$cmd' no encontrado. Instalalo y reintenta."
        exit 1
    fi
done

# En modo DRY_RUN solo se necesita DOMAINS
if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "*** MODO DRY_RUN: solo deteccion, no se tocara Cloudflare ***"
    if [[ -z "${DOMAINS:-}" ]]; then
        log "ERROR" "Variable requerida DOMAINS no esta definida en .env"
        exit 1
    fi
else
    for var in CLOUDFLARE_API_TOKEN DOMAINS; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR" "Variable requerida $var no esta definida en .env"
            exit 1
        fi
    done
fi

# --- Helper API Cloudflare --------------------------------------------------

cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
        -H "Content-Type: application/json"
        "${CF_API_BASE}${endpoint}"
    )

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    local response
    response="$(curl --max-time 30 "${args[@]}")"

    local http_code
    http_code="$(echo "$response" | tail -1)"
    local body
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log "ERROR" "Cloudflare API $method $endpoint -> HTTP $http_code"
        return 1
    fi

    local success
    success="$(echo "$body" | jq -r '.success' 2>/dev/null || echo "false")"
    if [[ "$success" != "true" ]]; then
        log "ERROR" "Cloudflare API error: $(echo "$body" | jq -c '.errors' 2>/dev/null)"
        return 1
    fi

    echo "$body"
}

# =============================================================================
# PASO 1: Resolver IPs de nuestros dominios y comprobar contra hayahora.futbol
# =============================================================================

log "INFO" "Comprobando estado de bloqueos LaLiga para nuestros dominios..."

# Si ya deshabilitamos el proxy, dig devuelve las IPs de origen (no las de Cloudflare).
# En ese caso, usar las IPs de Cloudflare guardadas en el state file.
existing_state="$(read_state)"
existing_state_len="$(echo "$existing_state" | jq 'length')"

CF_IPS_FILE="${STATE_FILE%.json}_ips.json"
if [[ "$existing_state_len" -gt 0 ]] && [[ -f "$CF_IPS_FILE" ]] && [[ -s "$CF_IPS_FILE" ]]; then
    # Proxy deshabilitado: usar las IPs de Cloudflare guardadas (no las de origen)
    our_ips=()
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && our_ips+=("$ip")
    done < <(jq -r '.[]' "$CF_IPS_FILE" 2>/dev/null)
    log "INFO" "Usando IPs de Cloudflare guardadas (proxy deshabilitado)"
elif [[ "$existing_state_len" -gt 0 ]]; then
    # State file existe pero NO hay archivo de IPs (script antiguo).
    # dig devolveria IPs de origen, no las de Cloudflare -> no fiable.
    # Fallback: comprobar si hay CUALQUIER bloqueo de Cloudflare activo.
    log "WARN" "State file sin IPs guardadas (version antigua). Usando check amplio de Cloudflare."
    our_ips=("__CHECK_ALL_CLOUDFLARE__")
else
    # Sin state file: resolver IPs frescas con dig y filtrar solo Cloudflare
    IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
    our_ips=()

    for entry in "${DOMAIN_LIST[@]}"; do
        entry="$(echo "$entry" | xargs)"
        domain="${entry#*:}"
        if [[ -z "$domain" ]]; then continue; fi

        while IFS= read -r ip; do
            if [[ -n "$ip" ]] && is_cloudflare_ip "$ip"; then
                our_ips+=("$ip")
            fi
        done < <(dig +short "$domain" A 2>/dev/null)
        while IFS= read -r ip; do
            if [[ -n "$ip" ]] && is_cloudflare_ip "$ip"; then
                our_ips+=("$ip")
            fi
        done < <(dig +short "$domain" AAAA 2>/dev/null)
    done

    if [[ ${#our_ips[@]} -eq 0 ]]; then
        log "WARN" "Ninguna IP resuelta es de Cloudflare. El proxy podria estar desactivado manualmente."
        log "INFO" "Abortando. Si el proxy esta activo, comprueba la configuracion de DNS."
        exit 0
    fi
fi

# Eliminar duplicados (compatible bash 3)
our_ips_dedup=()
while IFS= read -r ip; do
    [[ -n "$ip" ]] && our_ips_dedup+=("$ip")
done < <(printf '%s\n' "${our_ips[@]}" | sort -u)
our_ips=("${our_ips_dedup[@]}")

if [[ ${#our_ips[@]} -eq 0 ]]; then
    log "ERROR" "No se pudieron resolver IPs para ningun dominio. Abortando."
    exit 1
fi

log "INFO" "IPs a comprobar: ${our_ips[*]}"

MAX_DISABLED_SECONDS="${MAX_DISABLED_HOURS:-12}"
MAX_DISABLED_SECONDS=$((MAX_DISABLED_SECONDS * 3600))

hayahora_ok=true
hayahora_data="$(curl -s --max-time 15 "$HAYAHORA_API")" || hayahora_ok=false

if [[ "$hayahora_ok" == "true" ]] && ! echo "$hayahora_data" | jq empty 2>/dev/null; then
    hayahora_ok=false
fi

if [[ "$hayahora_ok" == "false" ]]; then
    log "WARN" "No se pudo obtener datos de $HAYAHORA_API"

    # Comprobar si hay state file con registros deshabilitados hace mas de MAX_DISABLED_HOURS
    current_state="$(read_state)"
    state_len="$(echo "$current_state" | jq 'length')"

    if [[ "$state_len" -eq 0 ]]; then
        log "INFO" "Sin state file activo. Abortando sin cambios (fail-safe)."
        exit 0
    fi

    # Comprobar antiguedad del primer registro deshabilitado
    oldest_ts="$(echo "$current_state" | jq -r '.[0].disabled_at')"
    # disabled_at puede ser epoch (numerico) o ISO 8601 (legacy)
    if [[ "$oldest_ts" =~ ^[0-9]+$ ]]; then
        oldest_epoch="$oldest_ts"
    else
        oldest_epoch="$(date -d "$oldest_ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$oldest_ts" +%s 2>/dev/null || echo "")"
    fi
    # Si no se pudo parsear, no asumir timeout -- esperar
    if [[ -z "$oldest_epoch" || "$oldest_epoch" == "0" ]]; then
        log "WARN" "No se pudo parsear disabled_at='$oldest_ts'. Esperando sin cambios."
        exit 0
    fi
    now_epoch="$(date +%s)"
    elapsed=$(( now_epoch - oldest_epoch ))

    if [[ "$elapsed" -ge "$MAX_DISABLED_SECONDS" ]]; then
        log "WARN" "Proxy deshabilitado hace $(( elapsed / 3600 ))h. Superado limite de ${MAX_DISABLED_HOURS:-12}h. Rehabilitando."
        blocking_active=false
        blocked_details="(hayahora caida, timeout ${MAX_DISABLED_HOURS:-12}h alcanzado)"
    else
        remaining_h=$(( (MAX_DISABLED_SECONDS - elapsed) / 3600 ))
        log "INFO" "Proxy deshabilitado hace $(( elapsed / 3600 ))h. Quedan ~${remaining_h}h hasta rehabilitar por timeout. Esperando."
        exit 0
    fi
else
    # Hayahora funciona: comprobar bloqueo
    if [[ "${our_ips[0]}" == "__CHECK_ALL_CLOUDFLARE__" ]]; then
        # Fallback: sin IPs guardadas, comprobar CUALQUIER bloqueo de Cloudflare
        blocked_count="$(echo "$hayahora_data" | jq '
            [.data[]
             | select(.description | test("^Cloudflare"))
             | select(.stateChanges | length > 0)
             | select(.stateChanges[-1].state == true)
            ] | length
        ')"

        if [[ "$blocked_count" -gt 0 ]]; then
            blocking_active=true
            blocked_details="(check amplio: $blocked_count IPs de Cloudflare bloqueadas)"
            log "WARN" "BLOQUEO CLOUDFLARE ACTIVO ($blocked_count IPs bloqueadas). Manteniendo proxy deshabilitado."
        else
            blocking_active=false
            log "INFO" "No hay bloqueos de Cloudflare activos. Se puede rehabilitar."
        fi
    else
        our_ips_json="$(printf '%s\n' "${our_ips[@]}" | jq -R . | jq -s .)"

        blocked_count="$(echo "$hayahora_data" | jq --argjson ours "$our_ips_json" '
            [.data[]
             | select(.ip as $ip | $ours | index($ip))
             | select(.stateChanges | length > 0)
             | select(.stateChanges[-1].state == true)
            ] | length
        ')"

        if [[ "$blocked_count" -gt 0 ]]; then
            blocking_active=true

            blocked_details="$(echo "$hayahora_data" | jq -r --argjson ours "$our_ips_json" '
                [.data[]
                 | select(.ip as $ip | $ours | index($ip))
                 | select(.stateChanges | length > 0)
                 | select(.stateChanges[-1].state == true)
                 | "\(.isp) bloqueando \(.ip)"
                ] | join("; ")
            ')"

            log "WARN" "BLOQUEO DE NUESTRAS IPs ($blocked_count entradas): $blocked_details"
        else
            blocking_active=false
            log "INFO" "Nuestras IPs NO estan bloqueadas"
        fi
    fi
fi

# =============================================================================
# PASO 2: Leer estado actual y decidir accion
# =============================================================================

current_state="$(read_state)"
state_count="$(echo "$current_state" | jq 'length')"
script_disabled_proxy=false
if [[ "$state_count" -gt 0 ]]; then
    script_disabled_proxy=true
fi

# Matriz de decision:
#   blocking=true  + state=false → DISABLE (primer bloqueo)
#   blocking=true  + state=true  → DISABLE (retomar tras crash, saltara los ya hechos)
#   blocking=false + state=true  → ENABLE
#   blocking=false + state=false → nada
if [[ "$blocking_active" == "true" ]]; then
    action="disable"
elif [[ "$blocking_active" == "false" && "$script_disabled_proxy" == "true" ]]; then
    action="enable"
else
    log "INFO" "Sin bloqueo y proxy activo. Sin accion."
    exit 0
fi

# En modo DRY_RUN: solo informar y salir
if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$action" == "disable" ]]; then
        if [[ "$script_disabled_proxy" == "true" ]]; then
            log "DRY_RUN" "Bloqueo activo. Ya hay $state_count registro(s) deshabilitado(s). Se comprobarian los restantes."
        else
            log "DRY_RUN" "ACCION NECESARIA: Hay bloqueo activo. Se DESHABILITARIA el proxy para: $(echo "$DOMAINS" | tr ',' '\n' | cut -d: -f2 | tr '\n' ', ')"
        fi
    else
        log "DRY_RUN" "ACCION NECESARIA: Bloqueo terminado. Se REHABILITARIA el proxy en $state_count registro(s)."
    fi
    log "DRY_RUN" "No se ha modificado nada en Cloudflare (modo prueba)"
    exit 0
fi

# =============================================================================
# PASO 3: Ejecutar accion
# =============================================================================

IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"

if [[ "$action" == "disable" ]]; then
    # -----------------------------------------------------------------
    # DESHABILITAR PROXY
    # -----------------------------------------------------------------
    log "INFO" "=== DESHABILITANDO proxy de Cloudflare ==="

    # Guardar las IPs de Cloudflare actuales (antes de cambiar el proxy)
    # Se usaran en siguientes ejecuciones para comprobar si el bloqueo sigue
    our_ips_save="$(printf '%s\n' "${our_ips[@]}" | jq -R . | jq -s .)"
    atomic_write "${STATE_FILE%.json}_ips.json" "$our_ips_save"

    # Inicializar state file si no existe
    if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
        atomic_write "$STATE_FILE" '[]'
    fi

    any_error=false
    total_disabled=0

    for entry in "${DOMAIN_LIST[@]}"; do
        entry="$(echo "$entry" | xargs)"
        zone_id="${entry%%:*}"
        domain="${entry#*:}"

        if [[ -z "$zone_id" || -z "$domain" ]]; then
            log "ERROR" "Entrada mal formada en DOMAINS: '$entry'. Formato: ZONE_ID:DOMINIO"
            any_error=true
            continue
        fi

        log "INFO" "Procesando dominio: $domain (zona: ${zone_id:0:8}...)"

        records_json="$(cf_api GET "/zones/${zone_id}/dns_records?per_page=100")" || {
            log "ERROR" "No se pudieron obtener registros DNS para $domain. Saltando."
            any_error=true
            continue
        }

        # Solo registros proxied del dominio y subdominios
        target_records="$(echo "$records_json" | jq -c --arg domain "$domain" '
            [.result[]
             | select(.type == "A" or .type == "AAAA" or .type == "CNAME")
             | select(.name == $domain or (.name | endswith("." + $domain)))
             | select(.proxiable == true)
             | select(.proxied == true)
             | {id, name, type, content, ttl}
            ]
        ')"

        record_count="$(echo "$target_records" | jq 'length')"

        if [[ "$record_count" -eq 0 ]]; then
            log "INFO" "  No hay registros proxied para $domain."
            continue
        fi

        log "INFO" "  $record_count registro(s) proxied encontrado(s)"

        for i in $(seq 0 $((record_count - 1))); do
            record="$(echo "$target_records" | jq -c ".[$i]")"
            record_id="$(echo "$record" | jq -r '.id')"
            record_name="$(echo "$record" | jq -r '.name')"
            record_type="$(echo "$record" | jq -r '.type')"
            record_content="$(echo "$record" | jq -r '.content')"
            record_ttl="$(echo "$record" | jq '.ttl')"

            # Saltar si ya esta en state file (crash anterior ya lo deshabilito)
            if jq -e --arg id "$record_id" '.[] | select(.record_id == $id)' "$STATE_FILE" >/dev/null 2>&1; then
                log "INFO" "  [SKIP] $record_name ya en state file (crash anterior)"
                continue
            fi

            patch_body="$(jq -n \
                --arg name "$record_name" \
                --arg type "$record_type" \
                --arg content "$record_content" \
                --argjson ttl "$record_ttl" \
                '{name: $name, type: $type, content: $content, ttl: $ttl, proxied: false}'
            )"

            if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$patch_body" >/dev/null; then
                log "INFO" "  [OK] Proxy deshabilitado: $record_type $record_name -> $record_content"
                total_disabled=$((total_disabled + 1))

                # Guardar en state file INMEDIATAMENTE tras cada PATCH exitoso
                new_state="$(jq \
                    --arg zid "$zone_id" \
                    --arg id "$record_id" \
                    --arg name "$record_name" \
                    --arg type "$record_type" \
                    --arg content "$record_content" \
                    --argjson ts "$(date +%s)" \
                    '. + [{zone_id: $zid, record_id: $id, name: $name, type: $type, content: $content, disabled_at: $ts}]' \
                    "$STATE_FILE" 2>/dev/null)" && atomic_write "$STATE_FILE" "$new_state" || {
                    log "ERROR" "  No se pudo actualizar state file para $record_name"
                    any_error=true
                }
            else
                log "ERROR" "  [FAIL] No se pudo deshabilitar proxy para $record_type $record_name"
                any_error=true
            fi
        done
    done

    final_count="$(jq 'length' "$STATE_FILE" 2>/dev/null || echo 0)"
    log "INFO" "Total en state file: $final_count registro(s) ($total_disabled nuevos en esta ejecucion)"

    # Notificar por Telegram solo si hubo cambios nuevos
    if [[ "$total_disabled" -gt 0 ]]; then
        records_list="$(jq -r '.[] | "  - \(.type) \(.name) → \(.content)"' "$STATE_FILE" 2>/dev/null)"
        notify_telegram "$(cat <<EOF
🔴 <b>Proxy Cloudflare DESHABILITADO</b>

LaLiga ha activado bloqueos. Se ha quitado el proxy (nube naranja → gris) en $final_count registro(s):

<code>$records_list</code>

Motivo: $blocked_details
EOF
)"
    fi

    if [[ "$any_error" == "true" ]]; then
        log "WARN" "Algunos registros fallaron. Se reintentara en la proxima ejecucion."
    fi

elif [[ "$action" == "enable" ]]; then
    # -----------------------------------------------------------------
    # REHABILITAR PROXY
    # -----------------------------------------------------------------
    log "INFO" "=== REHABILITANDO proxy de Cloudflare ==="

    state_records="$(read_state)"
    record_count="$(echo "$state_records" | jq 'length')"

    if [[ "$record_count" -eq 0 ]]; then
        log "INFO" "State file vacio. Nada que rehabilitar."
        rm -f "$STATE_FILE" "${STATE_FILE%.json}_ips.json"
        exit 0
    fi

    log "INFO" "Restaurando $record_count registro(s) deshabilitado(s) previamente"

    any_error=false
    total_enabled=0

    for i in $(seq 0 $((record_count - 1))); do
        zone_id="$(echo "$state_records" | jq -r ".[$i].zone_id")"
        record_id="$(echo "$state_records" | jq -r ".[$i].record_id")"
        record_name="$(echo "$state_records" | jq -r ".[$i].name")"

        # Obtener estado actual del registro en Cloudflare
        current="$(cf_api GET "/zones/${zone_id}/dns_records/${record_id}")" || {
            log "ERROR" "  No se pudo obtener registro $record_id ($record_name). Saltando."
            any_error=true
            continue
        }

        current_proxied="$(echo "$current" | jq '.result.proxied')"

        if [[ "$current_proxied" == "true" ]]; then
            log "INFO" "  [SKIP] $record_name ya tiene proxy activo"
        else
            record_type="$(echo "$current" | jq -r '.result.type')"
            record_content="$(echo "$current" | jq -r '.result.content')"
            record_ttl="$(echo "$current" | jq '.result.ttl')"

            patch_body="$(jq -n \
                --arg name "$record_name" \
                --arg type "$record_type" \
                --arg content "$record_content" \
                --argjson ttl "$record_ttl" \
                '{name: $name, type: $type, content: $content, ttl: $ttl, proxied: true}'
            )"

            if cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$patch_body" >/dev/null; then
                log "INFO" "  [OK] Proxy rehabilitado: $record_type $record_name"
                total_enabled=$((total_enabled + 1))
            else
                log "ERROR" "  [FAIL] No se pudo rehabilitar proxy para $record_name"
                any_error=true
                continue  # No eliminar del state file si fallo
            fi
        fi

        # Eliminar este registro del state file INMEDIATAMENTE (crash-safe)
        new_state="$(jq --arg id "$record_id" 'map(select(.record_id != $id))' "$STATE_FILE" 2>/dev/null)" \
            && atomic_write "$STATE_FILE" "$new_state" || {
            log "ERROR" "  No se pudo actualizar state file tras rehabilitar $record_name"
            any_error=true
        }
    done

    # Si el state file quedo vacio, eliminarlo
    remaining="$(jq 'length' "$STATE_FILE" 2>/dev/null || echo 0)"
    if [[ "$remaining" -eq 0 ]]; then
        rm -f "$STATE_FILE" "${STATE_FILE%.json}_ips.json"
        log "INFO" "Todos los registros restaurados. State file eliminado."

        restored_list="$(echo "$state_records" | jq -r '.[] | "  - \(.type) \(.name)"')"
        notify_telegram "$(cat <<EOF
🟢 <b>Proxy Cloudflare REHABILITADO</b>

El bloqueo de LaLiga ha terminado. Se ha restaurado el proxy (nube gris → naranja) en $record_count registro(s):

<code>$restored_list</code>
EOF
)"
    else
        log "WARN" "$remaining registro(s) no se pudieron rehabilitar. Se reintentara en la proxima ejecucion."
    fi
fi

log "INFO" "Hecho."
