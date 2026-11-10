#!/bin/bash
# =============================================================================
# migrate-to-data.sh
# Migrasi storage Nextcloud Docker dari Docker named volume ke /data bind mount
#
# SEBELUM:  nextcloud_data  → /var/lib/docker/volumes/nextcloud-docker_nextcloud_data/_data
#           db_data         → /var/lib/docker/volumes/nextcloud-docker_db_data/_data
#
# SESUDAH:  /data/nextcloud/html   → /var/www/html   (nextcloud files)
#           /data/nextcloud/db     → /var/lib/postgresql/data
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/migrate-to-data.log"

# Target directory di /data
DATA_ROOT="/data/nextcloud"
NC_DATA_DIR="${DATA_ROOT}/html"
DB_DATA_DIR="${DATA_ROOT}/db"

# Docker volume sumber
VOL_NC="nextcloud-docker_nextcloud_data"
VOL_DB="nextcloud-docker_db_data"

# Container names
CONTAINER_APP="nextcloud-app"
CONTAINER_DB="nextcloud-db"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC_C='\033[0m'

log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "${LOG_FILE}"; }
info()    { log "INFO " "${CYAN}${*}${NC_C}"; }
success() { log "OK   " "${GREEN}${*}${NC_C}"; }
warn()    { log "WARN " "${YELLOW}${*}${NC_C}"; }
error()   { log "ERROR" "${RED}${*}${NC_C}"; exit 1; }
confirm() {
    echo -e "${YELLOW}${1}${NC_C}"
    read -r -p "Ketik 'ya' untuk melanjutkan: " ans
    [[ "${ans}" == "ya" ]] || { warn "Dibatalkan."; exit 0; }
}

# ─────────────────────────────────────────────────────────────
# STEP 0: Validasi pra-migrasi
# ─────────────────────────────────────────────────────────────
step0_validate() {
    info "═══ STEP 0: Validasi pra-migrasi ═══"

    # Pastikan /data mount dan writable
    if ! mountpoint -q /data 2>/dev/null && ! df /data &>/dev/null; then
        error "/data bukan mountpoint yang valid."
    fi

    local free_gb
    free_gb=$(df -BG /data | awk 'NR==2 {gsub("G","",$4); print $4}')
    info "Ruang bebas di /data: ${free_gb}GB"
    if [[ "${free_gb}" -lt 200 ]]; then
        warn "Ruang bebas < 200GB. Pastikan cukup untuk seluruh data Nextcloud!"
        confirm "Lanjutkan meski ruang terbatas?"
    fi

    # Pastikan volume sumber ada
    docker volume inspect "${VOL_NC}" &>/dev/null \
        || error "Volume ${VOL_NC} tidak ditemukan!"
    docker volume inspect "${VOL_DB}" &>/dev/null \
        || error "Volume ${VOL_DB} tidak ditemukan!"

    # Pastikan container running
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_APP}$" \
        || error "Container ${CONTAINER_APP} tidak running. Jalankan dulu: docker compose up -d"

    success "Validasi pra-migrasi OK."
}

# ─────────────────────────────────────────────────────────────
# STEP 1: Buat direktori target di /data
# ─────────────────────────────────────────────────────────────
step1_prepare_dirs() {
    info "═══ STEP 1: Menyiapkan direktori di /data ═══"

    mkdir -p "${NC_DATA_DIR}" "${DB_DATA_DIR}"

    # Samakan kepemilikan dengan yang dipakai container
    # Nextcloud app berjalan sebagai www-data (uid 33)
    chown 33:33 "${NC_DATA_DIR}"
    # Postgres berjalan sebagai postgres (uid 999 di image postgres:14)
    chown 999:999 "${DB_DATA_DIR}"

    success "Direktori siap: ${NC_DATA_DIR} & ${DB_DATA_DIR}"
}

# ─────────────────────────────────────────────────────────────
# STEP 2: Enable maintenance mode & stop containers
# ─────────────────────────────────────────────────────────────
step2_stop() {
    info "═══ STEP 2: Aktifkan maintenance mode & stop containers ═══"

    # Aktifkan maintenance mode
    if docker exec "${CONTAINER_APP}" php occ maintenance:mode --on 2>/dev/null; then
        success "Maintenance mode ON."
    else
        warn "Gagal aktifkan maintenance mode via occ (mungkin sedang upgrade). Lanjut..."
    fi

    # Stop containers (bukan remove)
    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" stop
    success "Containers dihentikan."
}

# ─────────────────────────────────────────────────────────────
# STEP 3: Salin data menggunakan container helper (rsync)
# ─────────────────────────────────────────────────────────────
step3_copy_data() {
    info "═══ STEP 3: Menyalin data Nextcloud (137GB — bisa memakan waktu ~15-30 menit) ═══"

    # Gunakan container sementara yang mount volume lama dan direktori baru
    info "Menyalin nextcloud_data → ${NC_DATA_DIR} ..."
    docker run --rm \
        -v "${VOL_NC}:/source:ro" \
        -v "${NC_DATA_DIR}:/dest" \
        alpine sh -c "
            apk add --no-cache rsync -q
            rsync -a --info=progress2 /source/ /dest/
            echo 'rsync nextcloud_data selesai.'
        "
    success "Data Nextcloud berhasil disalin ke ${NC_DATA_DIR}."

    info "Menyalin db_data → ${DB_DATA_DIR} ..."
    docker run --rm \
        -v "${VOL_DB}:/source:ro" \
        -v "${DB_DATA_DIR}:/dest" \
        alpine sh -c "
            apk add --no-cache rsync -q
            rsync -a --info=progress2 /source/ /dest/
            echo 'rsync db_data selesai.'
        "
    success "Data PostgreSQL berhasil disalin ke ${DB_DATA_DIR}."
}

# ─────────────────────────────────────────────────────────────
# STEP 4: Verifikasi integritas data (bandingkan jumlah file & ukuran)
# ─────────────────────────────────────────────────────────────
step4_verify() {
    info "═══ STEP 4: Verifikasi integritas data ═══"

    # Hitung file di volume lama (via container)
    local src_nc_count src_db_size dest_nc_count dest_db_size

    info "Menghitung file di sumber (nextcloud_data)..."
    src_nc_count=$(docker run --rm -v "${VOL_NC}:/src:ro" alpine sh -c "find /src -type f | wc -l" 2>/dev/null)

    info "Menghitung file di tujuan (${NC_DATA_DIR})..."
    dest_nc_count=$(docker run --rm -v "${NC_DATA_DIR}:/dest:ro" alpine sh -c "find /dest -type f | wc -l" 2>/dev/null)

    info "Nextcloud files — sumber: ${src_nc_count}, tujuan: ${dest_nc_count}"
    if [[ "${src_nc_count}" -ne "${dest_nc_count}" ]]; then
        error "Jumlah file tidak cocok! src=${src_nc_count} dest=${dest_nc_count}. Batalkan dan periksa."
    fi
    success "✓ Jumlah file Nextcloud cocok: ${dest_nc_count} file."

    info "Memeriksa ukuran DB..."
    src_db_size=$(docker run --rm -v "${VOL_DB}:/src:ro" alpine sh -c "du -s /src | awk '{print \$1}'" 2>/dev/null)
    dest_db_size=$(docker run --rm -v "${DB_DATA_DIR}:/dest:ro" alpine sh -c "du -s /dest | awk '{print \$1}'" 2>/dev/null)
    info "DB size — sumber: ${src_db_size}K, tujuan: ${dest_db_size}K"

    local diff=$(( src_db_size - dest_db_size ))
    [[ ${diff} -lt 0 ]] && diff=$(( -diff ))
    # Toleransi 1%
    local threshold=$(( src_db_size / 100 ))
    if [[ ${diff} -gt ${threshold} ]]; then
        error "Ukuran DB berbeda terlalu jauh! Periksa hasil copy."
    fi
    success "✓ Ukuran DB cocok (toleransi 1%)."
}

# ─────────────────────────────────────────────────────────────
# STEP 5: Update docker-compose.yml → gunakan bind mount ke /data
# ─────────────────────────────────────────────────────────────
step5_update_compose() {
    info "═══ STEP 5: Update docker-compose.yml ═══"

    # Backup docker-compose.yml dulu
    cp "${COMPOSE_FILE}" "${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    success "Backup docker-compose.yml dibuat."

    # Tulis docker-compose.yml baru dengan bind mount
    cat > "${COMPOSE_FILE}" << YAML
services:
  db:
    image: postgres:14
    container_name: nextcloud-db
    restart: always

    environment:
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}

    volumes:
      - ${DB_DATA_DIR}:/var/lib/postgresql/data

    networks:
      - production_network

  app:
    image: nextcloud:35-apache
    container_name: nextcloud-app
    restart: always

    expose:
      - "80"

    environment:
      POSTGRES_HOST: \${POSTGRES_HOST}
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}

      NEXTCLOUD_DOMAIN: \${NEXTCLOUD_DOMAIN}
      NEXTCLOUD_PROTOCOL: \${NEXTCLOUD_PROTOCOL}

    volumes:
      - ${NC_DATA_DIR}:/var/www/html
      - ./config:/opt/config
      - ./entrypoint.sh:/docker-entrypoint-hooks.d/before-starting/10-domain.sh:ro

    depends_on:
      - db

    networks:
      - production_network

networks:
  production_network:
    external: true
YAML

    success "docker-compose.yml diperbarui dengan bind mount ke /data."
}

# ─────────────────────────────────────────────────────────────
# STEP 6: Jalankan ulang dan verifikasi
# ─────────────────────────────────────────────────────────────
step6_start_and_verify() {
    info "═══ STEP 6: Menjalankan ulang Nextcloud ═══"

    cd "${SCRIPT_DIR}"
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d

    info "Menunggu container siap..."
    local max=90 elapsed=0
    until docker exec "${CONTAINER_APP}" php occ status &>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
        if [[ ${elapsed} -ge ${max} ]]; then
            error "Timeout: container tidak siap setelah ${max}s. Cek: docker compose logs"
        fi
    done
    echo ""

    # Matikan maintenance mode
    docker exec "${CONTAINER_APP}" php occ maintenance:mode --off
    success "Maintenance mode OFF."

    # Tampilkan status akhir
    echo ""
    echo -e "${CYAN}═══════════ STATUS AKHIR ═══════════${NC_C}"
    docker exec "${CONTAINER_APP}" php occ status
    echo ""

    local version
    version=$(docker exec "${CONTAINER_APP}" php occ status | grep 'version:' | awk '{print $3}')
    local needs_upgrade
    needs_upgrade=$(docker exec "${CONTAINER_APP}" php occ status | grep 'needsDbUpgrade:' | awk '{print $3}')

    if [[ "${needs_upgrade}" == "true" ]]; then
        warn "needsDbUpgrade=true — jalankan: docker exec nextcloud-app php occ upgrade"
    fi

    success "════════════════════════════════════════"
    success "✓ Migrasi selesai! Nextcloud ${version} berjalan dari /data"
    success "  Nextcloud files : ${NC_DATA_DIR}"
    success "  PostgreSQL data : ${DB_DATA_DIR}"
    success "════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────
# STEP 7: Info volume lama (tidak dihapus otomatis)
# ─────────────────────────────────────────────────────────────
step7_cleanup_info() {
    info "═══ STEP 7: Volume lama (TIDAK dihapus otomatis) ═══"
    warn "Volume Docker lama masih ada sebagai backup:"
    warn "  - ${VOL_NC}"
    warn "  - ${VOL_DB}"
    warn ""
    warn "Setelah dipastikan Nextcloud berjalan normal selama beberapa hari,"
    warn "hapus volume lama dengan perintah:"
    warn "  docker volume rm ${VOL_NC}"
    warn "  docker volume rm ${VOL_DB}"
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC_C}"
    echo -e "${CYAN}║   MIGRASI NEXTCLOUD STORAGE → /data                  ║${NC_C}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC_C}"
    echo ""
    echo -e "  Sumber  : Docker named volumes (di /var/lib/docker/volumes/)"
    echo -e "  Tujuan  : ${GREEN}${NC_DATA_DIR}${NC_C}  &  ${GREEN}${DB_DATA_DIR}${NC_C}"
    echo ""
    warn "Proses ini akan:"
    warn "  1. Aktifkan maintenance mode Nextcloud"
    warn "  2. Stop containers sementara"
    warn "  3. Copy semua data (~137GB) ke /data  ← bisa 15-30 menit"
    warn "  4. Verifikasi integritas data"
    warn "  5. Update docker-compose.yml"
    warn "  6. Restart Nextcloud dari lokasi baru"
    warn ""
    confirm "⚠  Lanjutkan migrasi? (Nextcloud akan DOWN sementara selama proses copy)"

    step0_validate
    step1_prepare_dirs
    step2_stop
    step3_copy_data
    step4_verify
    step5_update_compose
    step6_start_and_verify
    step7_cleanup_info

    log "INFO " "Migrasi selesai pada $(date '+%Y-%m-%d %H:%M:%S')"
}

main "$@"
