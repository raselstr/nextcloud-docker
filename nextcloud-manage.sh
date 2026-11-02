#!/bin/bash
# =============================================================================
# nextcloud-manage.sh
# Script manajemen Nextcloud Docker: start, stop, restart, update, dan cek status
# Deteksi otomatis versi major terbaru via GitHub API + Docker Hub
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/nextcloud-manage.log"
CONTAINER_APP="nextcloud-app"
CONTAINER_DB="nextcloud-db"
DOCKER_NETWORK="production_network"

# Notifikasi (opsional) — isi NOTIFY_URL dengan webhook Slack/Discord/n8n/dll
# Kosongkan untuk menonaktifkan
NOTIFY_URL=""

# Warna terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────
# FUNGSI UTILITAS
# ─────────────────────────────────────────────────────────────

notify() {
    # Kirim notifikasi ke webhook jika NOTIFY_URL diisi
    local msg="$1"
    if [[ -n "${NOTIFY_URL:-}" ]]; then
        curl -s -X POST "${NOTIFY_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"[Nextcloud] ${msg}\"}" &>/dev/null || true
    fi
}

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

preflight() {
    local key

    command -v docker >/dev/null 2>&1 || {
        error "Docker tidak ditemukan. Pasang Docker terlebih dahulu."
        exit 1
    }
    docker compose version >/dev/null 2>&1 || {
        error "Docker Compose plugin tidak tersedia."
        exit 1
    }
    docker info >/dev/null 2>&1 || {
        error "Docker daemon tidak berjalan atau akses ditolak."
        exit 1
    }

    [[ -f "${COMPOSE_FILE}" ]] || {
        error "File Compose tidak ditemukan: ${COMPOSE_FILE}"
        exit 1
    }
    [[ -f "${ENV_FILE}" ]] || {
        error "File konfigurasi tidak ditemukan: ${ENV_FILE}"
        exit 1
    }

    for key in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST NEXTCLOUD_DOMAIN NEXTCLOUD_PROTOCOL; do
        if ! grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*[^[:space:]#]" "${ENV_FILE}"; then
            error "Variabel ${key} belum diisi di ${ENV_FILE}."
            exit 1
        fi
    done

    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" config --quiet || {
        error "Validasi konfigurasi Docker Compose gagal."
        exit 1
    }
}

ensure_network() {
    if ! docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1; then
        info "Membuat jaringan Docker ${DOCKER_NETWORK}..."
        docker network create "${DOCKER_NETWORK}" >/dev/null
    fi
}

wait_for_db() {
    info "Menunggu database PostgreSQL siap..."
    local max=120 elapsed=0
    until docker exec "${CONTAINER_DB}" pg_isready -q >/dev/null 2>&1; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [[ ${elapsed} -ge ${max} ]]; then
            error "Timeout: database tidak siap setelah ${max}s. Periksa log container database."
            exit 1
        fi
    done
    success "Database siap."
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

ensure_app_ready() {
    preflight
    ensure_network

    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d db
    wait_for_db
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d app
    wait_for_app

    local needs_upgrade maintenance
    needs_upgrade=$(occ status 2>/dev/null | awk -F': ' '$1 ~ /needsDbUpgrade/ {print $2; exit}')
    maintenance=$(occ status 2>/dev/null | awk -F': ' '$1 ~ /maintenance/ {print $2; exit}')

    if [[ "${needs_upgrade}" == "true" ]]; then
        info "Database upgrade tertunda; menjalankan 'occ upgrade'..."
        occ upgrade
        post_upgrade
    elif [[ "${maintenance}" == "true" ]]; then
        warn "Maintenance mode tertinggal; menjalankan repair sebelum mengaktifkan layanan..."
        post_upgrade
    fi
}

# ─────────────────────────────────────────────────────────────
# PERINTAH UTAMA
# ─────────────────────────────────────────────────────────────

cmd_start() {
    info "Menjalankan Nextcloud..."
    ensure_app_ready
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
    ensure_app_ready
    cmd_status
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
    ensure_app_ready

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

# ─────────────────────────────────────────────────────────────
# DETEKSI VERSI TERBARU (GitHub API + Docker Hub)
# ─────────────────────────────────────────────────────────────

get_latest_major_from_github() {
    # Kembalikan angka major version terbaru yang stable dari GitHub releases
    # Contoh output: "35"
    curl -s "https://api.github.com/repos/nextcloud/server/releases?per_page=30" \
    | python3 -c "
import sys, json, re
try:
    releases = json.load(sys.stdin)
    seen = {}
    for r in releases:
        tag = r.get('tag_name','')
        m = re.match(r'^v(\d+)\.(\d+)\.(\d+)', tag)
        if m and not r.get('prerelease') and not r.get('draft'):
            major = int(m.group(1))
            if major not in seen:
                seen[major] = (int(m.group(2)), int(m.group(3)), tag)
    latest = max(seen.keys())
    print(latest)
except Exception as e:
    sys.exit(1)
" 2>/dev/null
}

get_latest_patch_from_github() {
    # Kembalikan versi patch terbaru untuk major tertentu
    # Contoh: get_latest_patch_from_github 34  →  "34.0.5"
    local major="${1}"
    curl -s "https://api.github.com/repos/nextcloud/server/releases?per_page=30" \
    | python3 -c "
import sys, json, re
major = int('${major}')
try:
    releases = json.load(sys.stdin)
    best = None
    for r in releases:
        tag = r.get('tag_name','')
        m = re.match(r'^v(\d+)\.(\d+)\.(\d+)', tag)
        if m and int(m.group(1)) == major and not r.get('prerelease') and not r.get('draft'):
            ver = (int(m.group(2)), int(m.group(3)))
            if best is None or ver > best[0]:
                best = (ver, tag)
    if best:
        print(best[1].lstrip('v'))
except:
    sys.exit(1)
" 2>/dev/null
}

major_tag_exists_on_dockerhub() {
    # Cek apakah tag XX-apache tersedia di Docker Hub
    local major="${1}"
    curl -s "https://hub.docker.com/v2/repositories/library/nextcloud/tags/${major}-apache" \
        2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'name' in d else 'no')
except:
    print('no')
"
}

cmd_check_version() {
    echo ""
    echo -e "${CYAN}═══════════ CEK VERSI NEXTCLOUD ═══════════${NC}"
    ensure_app_ready

    # Versi terpasang
    local installed_version
    installed_version=$(occ status 2>/dev/null | grep 'version:' | awk '{print $3}')
    local installed_major
    installed_major=$(echo "${installed_version}" | cut -d. -f1)

    echo -e "  Versi terpasang    : ${GREEN}${installed_version}${NC} (major ${installed_major})"

    # Cek GitHub
    info "Memeriksa versi terbaru via GitHub API..."
    local latest_major
    latest_major=$(get_latest_major_from_github)
    local latest_patch_current_major
    latest_patch_current_major=$(get_latest_patch_from_github "${installed_major}")
    local latest_patch_latest_major
    latest_patch_latest_major=$(get_latest_patch_from_github "${latest_major}")

    echo -e "  Patch terbaru (v${installed_major}): ${YELLOW}${latest_patch_current_major}${NC}"
    echo -e "  Major terbaru      : ${YELLOW}v${latest_major} (${latest_patch_latest_major})${NC}"
    echo ""

    # Bandingkan
    local installed_major_ver
    installed_major_ver=$(echo "${installed_version}" | cut -d. -f1)

    if [[ "${latest_major}" -gt "${installed_major_ver}" ]]; then
        warn "⬆  Ada MAJOR VERSION baru: ${installed_major_ver} → ${latest_major}"
        warn "   Jalankan: $0 auto-upgrade"
        echo ""
        # Cek apakah sudah ada di Docker Hub
        local hub_available
        hub_available=$(major_tag_exists_on_dockerhub "${latest_major}")
        if [[ "${hub_available}" == "yes" ]]; then
            success "✓  Image nextcloud:${latest_major}-apache sudah tersedia di Docker Hub."
        else
            warn "✗  Image nextcloud:${latest_major}-apache BELUM tersedia di Docker Hub."
        fi
    else
        success "✓  Sudah menggunakan major version terbaru (v${latest_major})."
    fi

    # Cek patch update di major yang sama
    local iv_minor iv_patch lp_minor lp_patch
    iv_minor=$(echo "${installed_version}" | cut -d. -f2)
    iv_patch=$(echo "${installed_version}" | cut -d. -f3)
    lp_minor=$(echo "${latest_patch_current_major}" | cut -d. -f2)
    lp_patch=$(echo "${latest_patch_current_major}" | cut -d. -f3)
    if [[ "${lp_minor}" -gt "${iv_minor}" ]] || \
       { [[ "${lp_minor}" -eq "${iv_minor}" ]] && [[ "${lp_patch}" -gt "${iv_patch}" ]]; }; then
        warn "⬆  Ada patch update: ${installed_version} → ${latest_patch_current_major}"
        warn "   Jalankan: $0 update"
    else
        success "✓  Versi patch sudah terkini."
    fi
    echo ""
}

cmd_upgrade_major() {
    # Upgrade antar major version (mis. 33 → 34)
    local target_major="${1:-}"
    if [[ -z "${target_major}" ]]; then
        error "Gunakan: $0 upgrade-major <major_version>  (contoh: $0 upgrade-major 35)"
        exit 1
    fi

    ensure_app_ready

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

        # Cek Docker Hub dulu sebelum upgrade
        local available
        available=$(major_tag_exists_on_dockerhub "${next}")
        if [[ "${available}" != "yes" ]]; then
            error "Image nextcloud:${next}-apache belum tersedia di Docker Hub. Hentikan."
            exit 1
        fi

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
        notify "Major upgrade selesai: v${v} → v${next} (${ver})"

        v="${next}"
    done

    success "Semua major upgrade selesai. Versi aktif: $(occ status | grep 'version:' | awk '{print $3}')"
}

cmd_auto_upgrade() {
    # Deteksi versi terbaru dan upgrade otomatis (patch + major)
    echo ""
    echo -e "${CYAN}═══════════ AUTO-UPGRADE NEXTCLOUD ═══════════${NC}"
    ensure_app_ready

    local installed_version
    installed_version=$(occ status 2>/dev/null | grep 'version:' | awk '{print $3}')
    local installed_major
    installed_major=$(echo "${installed_version}" | cut -d. -f1)

    info "Versi terpasang: ${installed_version} (major ${installed_major})"
    info "Memeriksa versi terbaru via GitHub API..."

    local latest_major
    latest_major=$(get_latest_major_from_github)

    if [[ -z "${latest_major}" ]]; then
        error "Gagal mengambil informasi versi terbaru dari GitHub. Periksa koneksi internet."
        exit 1
    fi

    info "Major terbaru yang tersedia: v${latest_major}"

    if [[ "${latest_major}" -le "${installed_major}" ]]; then
        info "Tidak ada major upgrade. Memeriksa patch update..."
        cmd_update
        return
    fi

    # Ada major upgrade tersedia
    warn "Major upgrade tersedia: ${installed_major} → ${latest_major}"

    # Cek apakah semua image antara tersedia di Docker Hub
    local missing_images=()
    for ((v=installed_major+1; v<=latest_major; v++)); do
        local avail
        avail=$(major_tag_exists_on_dockerhub "${v}")
        if [[ "${avail}" != "yes" ]]; then
            missing_images+=("nextcloud:${v}-apache")
        fi
    done

    if [[ ${#missing_images[@]} -gt 0 ]]; then
        error "Image berikut belum tersedia di Docker Hub: ${missing_images[*]}"
        error "Tidak bisa upgrade otomatis. Tunggu hingga image tersedia."
        exit 1
    fi

    success "Semua image tersedia di Docker Hub. Memulai upgrade bertahap..."
    notify "Memulai auto-upgrade: v${installed_major} → v${latest_major}"

    # Jalankan upgrade major satu per satu
    cmd_upgrade_major "${latest_major}"

    # Setelah major upgrade, terapkan patch terbaru juga
    info "Memeriksa patch terbaru pasca major upgrade..."
    cmd_update

    local final_version
    final_version=$(occ status 2>/dev/null | grep 'version:' | awk '{print $3}')
    success "Auto-upgrade selesai. Versi akhir: ${final_version}"
    notify "Auto-upgrade selesai. Versi akhir: ${final_version}"
}

cmd_maintenance_off() {
    info "Mematikan maintenance mode..."
    ensure_app_ready
    occ maintenance:mode --off
    success "Maintenance mode dinonaktifkan."
}

cmd_backup_db() {
    local backup_dir="${SCRIPT_DIR}/backups"
    ensure_app_ready
    mkdir -p "${backup_dir}"
    local fname="nextcloud-db-$(date +%Y%m%d-%H%M%S).sql.gz"
    info "Backup database ke ${backup_dir}/${fname} ..."
    docker exec "${CONTAINER_DB}" sh -c 'exec pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
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
    echo -e "  ${YELLOW}check-version${NC}           Cek versi terbaru di GitHub & Docker Hub tanpa upgrade"
    echo -e "  ${YELLOW}update${NC}                  Cek & terapkan update patch (dalam major version yang sama)"
    echo -e "  ${YELLOW}auto-upgrade${NC}            Deteksi & upgrade otomatis (patch + major) via GitHub API"
    echo -e "  ${YELLOW}upgrade-major <ver>${NC}     Upgrade ke major version tertentu (mis: upgrade-major 35)"
    echo -e "  ${YELLOW}maintenance-off${NC}         Matikan maintenance mode secara paksa"
    echo -e "  ${YELLOW}backup-db${NC}               Backup database PostgreSQL"
    echo ""
    echo "Contoh:"
    echo "  $0 start"
    echo "  $0 check-version        # cek versi tanpa melakukan apa-apa"
    echo "  $0 update               # patch update (34.0.5 → 34.0.6)"
    echo "  $0 auto-upgrade         # otomatis patch + major (34 → 35)"
    echo "  $0 upgrade-major 35     # manual major upgrade ke v35"
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
        check-version)   cmd_check_version ;;
        update)          cmd_update ;;
        auto-upgrade)    cmd_auto_upgrade ;;
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

