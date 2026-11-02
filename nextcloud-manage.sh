#!/bin/bash
# =============================================================================
# nextcloud-manage.sh
# Script manajemen Nextcloud Docker: start, stop, restart, update, dan cek status
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/nextcloud-manage.log"
CONTAINER_APP="nextcloud-app"
CONTAINER_DB="nextcloud-db"

# Warna terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────
# FUNGSI UTILITAS
# ─────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${ts} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

info()    { log "INFO " "${CYAN}${*}${NC}"; }
success() { log "OK   " "${GREEN}${*}${NC}"; }
warn()    { log "WARN " "${YELLOW}${*}${NC}"; }
error()   { log "ERROR" "${RED}${*}${NC}"; }

occ() {
    docker exec "${CONTAINER_APP}" php occ "$@"
}

wait_for_app() {
    info "Menunggu container ${CONTAINER_APP} siap..."
    local max=60 elapsed=0
    until docker exec "${CONTAINER_APP}" php occ status &>/dev/null; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [[ ${elapsed} -ge ${max} ]]; then
            error "Timeout: container tidak siap setelah ${max}s"
            exit 1
        fi
    done
    success "Container siap."
}

db_maintenance() {
    info "Menjalankan pemeliharaan database..."
    occ db:add-missing-indices
    occ db:add-missing-columns
    occ db:add-missing-primary-keys
    success "Pemeliharaan database selesai."
}

post_upgrade() {
    info "Menjalankan repair pasca upgrade..."
    occ maintenance:repair
    db_maintenance
    occ maintenance:mode --off
    success "Repair pasca upgrade selesai."
}

# ─────────────────────────────────────────────────────────────
# PERINTAH UTAMA
# ─────────────────────────────────────────────────────────────

cmd_start() {
    info "Menjalankan Nextcloud..."
    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d
    wait_for_app
    success "Nextcloud berhasil dijalankan."
    cmd_status
}

cmd_stop() {
    info "Menghentikan Nextcloud..."
    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" down
    success "Nextcloud dihentikan."
}

cmd_restart() {
    info "Restart Nextcloud..."
    cmd_stop
    cmd_start
}

cmd_status() {
    echo ""
    echo -e "${CYAN}═══════════════ STATUS NEXTCLOUD ═══════════════${NC}"
    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" ps
    echo ""
    if docker exec "${CONTAINER_APP}" php occ status &>/dev/null; then
        echo -e "${GREEN}Nextcloud OCC Status:${NC}"
        occ status
        echo ""
        # Cek maintenance mode
        local maint
        maint=$(occ config:system:get maintenance 2>/dev/null || echo "false")
        if [[ "${maint}" == "true" ]]; then
            warn "⚠  Nextcloud dalam MAINTENANCE MODE!"
        else
            success "✓  Nextcloud berjalan normal (bukan maintenance mode)."
        fi
    else
        error "Container app tidak merespons occ."
    fi
    echo ""
}

cmd_logs() {
    local lines="${1:-100}"
    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" logs --tail="${lines}" -f
}

# ─────────────────────────────────────────────────────────────
# UPDATE / UPGRADE
# ─────────────────────────────────────────────────────────────

cmd_update() {
    info "════════ Memeriksa dan menerapkan update Nextcloud ════════"

    # Dapatkan versi saat ini di dalam container
    local current_version
    current_version=$(occ status 2>/dev/null | grep 'version:' | awk '{print $3}')
    info "Versi terpasang saat ini: ${current_version}"

    # Ambil image tag dari docker-compose.yml
    local image_tag
    image_tag=$(grep -E '^\s+image:\s+nextcloud:' "${COMPOSE_FILE}" | awk -F: '{print $NF}' | tr -d ' ')
    local major_version
    major_version=$(echo "${image_tag}" | grep -oE '^[0-9]+')
    info "Image tag aktif: nextcloud:${image_tag}"

    # Pull image terbaru untuk tag yang sama
    info "Menarik image terbaru untuk nextcloud:${image_tag}..."
    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" pull app

    # Cek apakah ada update dengan membandingkan image ID
    local old_image_id new_image_id running_image_id
    running_image_id=$(docker inspect "${CONTAINER_APP}" \
        --format '{{.Image}}' 2>/dev/null || echo "")
    new_image_id=$(docker images --no-trunc --quiet "nextcloud:${image_tag}" 2>/dev/null | head -1)

    if [[ "${running_image_id}" == "${new_image_id}" ]]; then
        success "Tidak ada update untuk nextcloud:${image_tag}. Nextcloud tetap berjalan."
        return 0
    fi

    warn "Update ditemukan! Menerapkan upgrade..."
    info "  Image lama : ${running_image_id:0:20}..."
    info "  Image baru : ${new_image_id:0:20}..."

    # Upgrade in-place (ganti container dengan image baru)
    info "Merestart container dengan image terbaru..."
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --force-recreate app

    wait_for_app

    # Jalankan occ upgrade jika diperlukan
    local needs_upgrade
    needs_upgrade=$(occ status 2>/dev/null | grep 'needsDbUpgrade:' | awk '{print $3}')
    if [[ "${needs_upgrade}" == "true" ]]; then
        info "Menjalankan 'occ upgrade'..."
        occ upgrade
    fi

    post_upgrade

    local new_version
    new_version=$(occ status 2>/dev/null | grep 'version:' | awk '{print $3}')
    success "════════ Upgrade selesai: ${current_version} → ${new_version} ════════"
    log "INFO " "Upgrade log: ${current_version} -> ${new_version} pada $(date '+%Y-%m-%d %H:%M:%S')"
}

cmd_upgrade_major() {
    # Upgrade antar major version (mis. 33 → 34)
    local target_major="${1:-}"
    if [[ -z "${target_major}" ]]; then
        error "Gunakan: $0 upgrade-major <major_version>  (contoh: $0 upgrade-major 35)"
        exit 1
    fi

    local current_tag
    current_tag=$(grep -E '^\s+image:\s+nextcloud:' "${COMPOSE_FILE}" | awk -F: '{print $NF}' | tr -d ' ')
    local current_major
    current_major=$(echo "${current_tag}" | grep -oE '^[0-9]+')

    if [[ "${target_major}" -le "${current_major}" ]]; then
        error "Target major (${target_major}) harus lebih besar dari versi saat ini (${current_major})."
        exit 1
    fi

    # Upgrade satu per satu dari current ke target
    local v="${current_major}"
    while [[ "${v}" -lt "${target_major}" ]]; do
        local next=$((v + 1))
        warn "━━━ Upgrade major: ${v} → ${next} ━━━"

        # Ganti tag di docker-compose.yml
        sed -i "s|image: nextcloud:${v}-apache|image: nextcloud:${next}-apache|g" "${COMPOSE_FILE}"

        cd "${SCRIPT_DIR}"
        docker compose -f "${COMPOSE_FILE}" pull app
        docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --force-recreate app

        wait_for_app

        info "Menjalankan occ upgrade untuk versi ${next}..."
        occ upgrade
        post_upgrade

        local ver
        ver=$(occ status 2>/dev/null | grep 'version:' | awk '{print $3}')
        success "Berhasil upgrade ke Nextcloud ${ver}"
        log "INFO " "Major upgrade: ${v} -> ${next} (${ver}) selesai pada $(date '+%Y-%m-%d %H:%M:%S')"

        v="${next}"
    done

    success "Semua major upgrade selesai. Versi aktif: $(occ status | grep 'version:' | awk '{print $3}')"
}

cmd_maintenance_off() {
    info "Mematikan maintenance mode..."
    occ maintenance:mode --off
    success "Maintenance mode dinonaktifkan."
}

cmd_backup_db() {
    local backup_dir="${SCRIPT_DIR}/backups"
    mkdir -p "${backup_dir}"
    local fname="nextcloud-db-$(date +%Y%m%d-%H%M%S).sql.gz"
    info "Backup database ke ${backup_dir}/${fname} ..."
    docker exec "${CONTAINER_DB}" pg_dump \
        -U "$(grep POSTGRES_USER "${ENV_FILE}" | cut -d= -f2)" \
        "$(grep POSTGRES_DB "${ENV_FILE}" | cut -d= -f2)" \
        | gzip > "${backup_dir}/${fname}"
    success "Backup selesai: ${backup_dir}/${fname}"
}

# ─────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────

usage() {
    echo ""
    echo -e "${CYAN}Nextcloud Docker Manager${NC}"
    echo ""
    echo -e "Usage: ${GREEN}$0 <perintah> [opsi]${NC}"
    echo ""
    echo "Perintah:"
    echo -e "  ${YELLOW}start${NC}                   Jalankan Nextcloud (docker compose up -d)"
    echo -e "  ${YELLOW}stop${NC}                    Hentikan Nextcloud"
    echo -e "  ${YELLOW}restart${NC}                 Restart Nextcloud"
    echo -e "  ${YELLOW}status${NC}                  Tampilkan status container dan OCC"
    echo -e "  ${YELLOW}logs [n]${NC}                Tampilkan log (default 100 baris, -f realtime)"
    echo -e "  ${YELLOW}update${NC}                  Cek & terapkan update patch (dalam major version yang sama)"
    echo -e "  ${YELLOW}upgrade-major <ver>${NC}     Upgrade ke major version baru (mis: upgrade-major 35)"
    echo -e "  ${YELLOW}maintenance-off${NC}         Matikan maintenance mode secara paksa"
    echo -e "  ${YELLOW}backup-db${NC}               Backup database PostgreSQL"
    echo ""
    echo "Contoh:"
    echo "  $0 start"
    echo "  $0 update"
    echo "  $0 upgrade-major 35"
    echo "  $0 logs 200"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift || true

    case "${cmd}" in
        start)           cmd_start ;;
        stop)            cmd_stop ;;
        restart)         cmd_restart ;;
        status)          cmd_status ;;
        logs)            cmd_logs "${@}" ;;
        update)          cmd_update ;;
        upgrade-major)   cmd_upgrade_major "${@}" ;;
        maintenance-off) cmd_maintenance_off ;;
        backup-db)       cmd_backup_db ;;
        help|--help|-h)  usage ;;
        *)
            error "Perintah tidak dikenal: ${cmd}"
            usage
            exit 1
            ;;
    esac
}

main "$@"

