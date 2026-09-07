#!/usr/bin/env bash
# =============================================================================
#  setup-fcos.sh — pause-groups installer for Fedora CoreOS
# =============================================================================
#
#  WHAT THIS SCRIPT DOES (in order):
#    Pre-flight  Verify the environment is ready (root, Podman, network, disk)
#    Step 0      Back up the existing database + encryption key (if any)
#    Step 1      Copy app files to /var/persist/pause-groups/ (survives reboots)
#    Step 2      Create the writable data directory
#    Step 3      Generate a random AES-256 encryption key
#    Step 4      Pull the PHP-FPM container image
#    Step 5      Run the interactive first-run installer (creates admin account)
#    Step 6      Fix file ownership for the PHP-FPM container user
#    Step 7      Create & start the PHP-FPM systemd service
#    Step 8      Create systemd timers (watchdog every minute, daily planner)
#    Step 9      Remove fresh_install.php (security)
#    Step 10     Generate the Nginx server block and save it to a file
#    Step 11     Verify services are running
#    Step 12     Print a final checklist of remaining manual steps
#
#  IMPORTANT — Nginx is NOT auto-edited.
#    The existing Nginx config at /var/persist/nginx.conf already has working
#    reverse-proxy rules for other services. Auto-patching it risks breaking
#    those. Instead, step 10 writes the exact block to add into a separate file
#    and tells you exactly where and how to paste it.
#
#  USAGE:
#    sudo bash setup-fcos.sh
#
#  RE-RUNNING:
#    Safe to re-run. Each step checks whether it has already been done and
#    skips or updates accordingly. The database will NOT be wiped on re-run.
#    Every run first snapshots your database + encryption key to
#    /var/persist/pause-groups-backups/<timestamp>/ (10 most recent kept).
#    To wipe and start completely fresh: sudo bash setup-fcos.sh --reset
#    (a backup is still taken before the wipe, so --reset is recoverable too)
#
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${BLU}[INFO]${NC}   $*"; }
ok()    { echo -e "${GRN}[OK]${NC}     $*"; }
warn()  { echo -e "${YLW}[WARN]${NC}   $*"; }
die()   { echo -e "${RED}[FATAL]${NC}  $*" >&2; exit 1; }
note()  { echo -e "${DIM}           $*${NC}"; }
hdr()   { echo -e "\n${BOLD}${CYN}── Step $* ${NC}"; }
pause() { echo -e "\n${YLW}Press Enter to continue...${NC}"; read -r; }

# ── Error trap — gives context when the script exits unexpectedly ─────────────
trap 'on_error $LINENO' ERR
on_error() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  Script failed at line $1                            ${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YLW}Troubleshooting:${NC}"
    echo "  • Read the error message above carefully."
    echo "  • Fix the issue, then re-run: sudo bash setup-fcos.sh"
    echo "  • This script is safe to re-run — it will skip completed steps."
    echo "  • For a completely fresh start: sudo bash setup-fcos.sh --reset"
    echo ""
}

# ── Flags ─────────────────────────────────────────────────────────────────────
DO_RESET=0
for arg in "$@"; do [[ "$arg" == "--reset" ]] && DO_RESET=1; done

# ── Configuration ─────────────────────────────────────────────────────────────
# These paths are correct for a standard FCOS setup.
# Only edit if your server uses non-standard paths.

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/var/persist/pause-groups"     # persists across FCOS rebuilds
DATA_DIR="${INSTALL_DIR}/data"              # database, logs, lock files
ENV_FILE="${INSTALL_DIR}/.env"             # stores encryption key (not web-accessible)
SNIPPET_FILE="/var/persist/pause-groups-nginx.conf.snippet"  # saved Nginx block
BACKUP_DIR="/var/persist/pause-groups-backups"  # timestamped DB + .env snapshots
                                           # (lives outside INSTALL_DIR so the
                                           # rsync --delete in step 1 never touches it)

PHP_IMAGE="docker.io/library/php:8.3-fpm" # official PHP image; change 8.3 if needed
PHP_PORT=9000                              # default port the php:fpm image listens on
                                           # (Nginx will proxy PHP requests here)

NGINX_CONF="/var/persist/nginx.conf"       # existing Nginx config — NOT auto-edited
SERVER_NAME="_"                            # Nginx server_name for this app.
                                           # Change to your hostname/IP, e.g.:
                                           #   SERVER_NAME="192.168.1.50"
                                           #   SERVER_NAME="pause.mycompany.local"
HTTP_PORT=80                               # Port for this vhost. Grafana uses 3000,
                                           # Tailscale VPN doesn't use a fixed port.
                                           # 80 is fine unless another vhost owns it.

# ── Backup helper ─────────────────────────────────────────────────────────────
# Snapshot the SQLite database (with its WAL/SHM sidecars) and the encryption
# key into a timestamped folder under ${BACKUP_DIR}. This is the safety net that
# makes re-running (or even --reset) recoverable: the two things you can never
# regenerate — your data and the key that decrypts your CenterEdge credentials —
# are copied somewhere the install never overwrites. A no-op on a fresh install.
backup_data() {
    local db="${DATA_DIR}/pause_groups.db"
    if [[ ! -f "$db" ]]; then
        info "No existing database to back up (fresh install)."
        return 0
    fi
    local stamp dest
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    dest="${BACKUP_DIR}/${stamp}"
    mkdir -p "$dest"
    # Copy the db and its journal sidecars together so the snapshot is
    # internally consistent even while WAL mode is active.
    cp -a "$db" "$dest/"
    if [[ -f "${db}-wal" ]]; then cp -a "${db}-wal" "$dest/"; fi
    if [[ -f "${db}-shm" ]]; then cp -a "${db}-shm" "$dest/"; fi
    if [[ -f "$ENV_FILE" ]];   then cp -a "$ENV_FILE" "$dest/env.bak"; fi
    chmod -R go-rwx "$dest" || true
    ok "Backed up database + encryption key to: ${dest}"

    # Keep only the 10 most recent backups so this can't fill the disk.
    local backups=()
    while IFS= read -r d; do backups+=("$d"); done \
        < <(ls -1dt "${BACKUP_DIR}"/*/ 2>/dev/null || true)
    if (( ${#backups[@]} > 10 )); then
        local i
        for (( i=10; i<${#backups[@]}; i++ )); do rm -rf "${backups[$i]}"; done
        note "Pruned old backups (kept the 10 most recent) in ${BACKUP_DIR}."
    fi
}

# =============================================================================
#  PRE-FLIGHT CHECKS
#  These run before any changes are made. All must pass before continuing.
# =============================================================================

echo ""
echo -e "${BOLD}${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GRN}║       pause-groups — Fedora CoreOS Setup             ║${NC}"
echo -e "${BOLD}${GRN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Source directory:  ${BOLD}${SOURCE_DIR}${NC}"
echo -e "  Install directory: ${BOLD}${INSTALL_DIR}${NC} (persists across rebuilds)"
echo -e "  PHP-FPM port:      ${BOLD}${PHP_PORT}${NC}"
echo -e "  Nginx config:      ${BOLD}${NGINX_CONF}${NC} (will NOT be auto-edited)"
echo ""

# ── Check: running as root ────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "Must be run as root. Try: sudo bash $0"
fi
ok "Running as root."

# ── Check: --reset flag ───────────────────────────────────────────────────────
if [[ $DO_RESET -eq 1 ]]; then
    echo ""
    warn "╔══════════════════════════════════════════════════════╗"
    warn "║  --reset flag detected                               ║"
    warn "║  This will DELETE the existing database and all      ║"
    warn "║  pause groups, schedules, overrides, and logs.      ║"
    warn "║  App files, the encryption key, and Nginx config    ║"
    warn "║  will NOT be deleted.                                ║"
    warn "╚══════════════════════════════════════════════════════╝"
    echo ""
    note "A timestamped backup of the database + key is taken before the wipe,"
    note "so this is recoverable from ${BACKUP_DIR}."
    echo ""
    read -r -p "  Type 'yes' to confirm reset, or anything else to abort: " RESET_CONFIRM
    if [[ "$RESET_CONFIRM" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
    if [[ -f "${DATA_DIR}/pause_groups.db" ]]; then
        info "Backing up the current database before deleting it..."
        backup_data
        rm -f "${DATA_DIR}/pause_groups.db" \
              "${DATA_DIR}/pause_groups.db-wal" \
              "${DATA_DIR}/pause_groups.db-shm"
        ok "Database deleted. Will create a fresh one during install."
    else
        info "No existing database found — nothing to reset."
    fi
fi

# ── Check: Podman is available ────────────────────────────────────────────────
echo ""
info "Checking for Podman..."
if ! command -v podman &>/dev/null; then
    die "podman not found.\n\n  This script requires Fedora CoreOS, which ships with Podman.\n  If you are on a different system, install Podman first."
fi
PODMAN_VER=$(podman --version | awk '{print $3}')
ok "Podman ${PODMAN_VER} found."

# ── Check: /var/persist exists ────────────────────────────────────────────────
info "Checking /var/persist..."
if [[ ! -d /var/persist ]]; then
    die "/var/persist does not exist.\n\n  On Fedora CoreOS, /var/persist is a bind-mounted VHDX that survives\n  OS rebuilds. It must exist before this script can run.\n\n  If you're testing on a non-FCOS system, create it manually:\n    sudo mkdir -p /var/persist"
fi
ok "/var/persist exists."

# ── Check: network connectivity ──────────────────────────────────────────────
info "Checking network connectivity (needed to pull the PHP image)..."
if ! curl -sf --max-time 10 https://registry-1.docker.io/v2/ -o /dev/null 2>/dev/null && \
   ! curl -sf --max-time 10 https://docker.io -o /dev/null 2>/dev/null; then
    die "Cannot reach Docker Hub (docker.io).\n\n  The PHP-FPM image must be pulled from the internet.\n  Check that the VM has outbound internet access.\n\n  If the image is already cached locally, skip this check by\n  temporarily commenting out the network check in this script."
fi
ok "Network connectivity confirmed."

# ── Check: openssl available ─────────────────────────────────────────────────
info "Checking for openssl (needed to generate encryption key)..."
if ! command -v openssl &>/dev/null; then
    die "openssl not found. It should be present on all Fedora CoreOS systems."
fi
ok "openssl found."

# ── Warn if existing install detected ────────────────────────────────────────
if [[ -f "${DATA_DIR}/pause_groups.db" ]]; then
    echo ""
    warn "╔══════════════════════════════════════════════════════╗"
    warn "║  Existing installation detected                      ║"
    warn "╚══════════════════════════════════════════════════════╝"
    warn "  Database already exists at: ${DATA_DIR}/pause_groups.db"
    warn "  This script will update app files and services"
    warn "  but will NOT wipe your database or admin account."
    warn "  To start completely fresh, re-run with: --reset"
    echo ""
    pause
fi

echo ""
echo -e "${BOLD}Pre-flight checks passed. Starting installation.${NC}"
echo ""

# =============================================================================
#  STEP 0 — BACK UP EXISTING DATA (before anything is copied or migrated)
# =============================================================================
# On a normal re-run this snapshots your DB + encryption key first, so even a
# mistaken edit, a bad migration, or a fat-fingered --reset later can be undone.
# On a --reset run the backup already happened above (before the wipe), so this
# is a no-op because the database is gone. On a fresh install there's nothing to
# back up and it prints a short notice.
hdr "0 of 12 — Back up existing data"
echo ""
note "Snapshots go to ${BACKUP_DIR} (outside the app dir, so they survive"
note "re-runs and FCOS rebuilds). The 10 most recent are kept."
echo ""
backup_data

# =============================================================================
#  STEP 1 — COPY APP FILES
# =============================================================================
hdr "1 of 12 — Copy app files to ${INSTALL_DIR}"
echo ""
note "Why: Fedora CoreOS is an immutable OS. Files placed in /var/"
note "persist are stored on a separate VHDX that survives OS rebuilds"
note "and automatic updates (Zincati). The app lives here permanently."
echo ""

if [[ "$SOURCE_DIR" == "$INSTALL_DIR" ]]; then
    ok "Already running from ${INSTALL_DIR} — no copy needed."
else
    mkdir -p "${INSTALL_DIR}"
    info "Copying files from ${SOURCE_DIR} to ${INSTALL_DIR}..."
    note "(Skipping: .git/, data/ — data/ is created separately in step 2)"
    echo ""

    # rsync gives clean progress; fall back to cp if not available
    if command -v rsync &>/dev/null; then
        rsync -a --delete \
            --exclude='.git/' \
            --exclude='data/' \
            --exclude='.env' \
            "${SOURCE_DIR}/" "${INSTALL_DIR}/"
    else
        # cp -a preserves timestamps and permissions
        cp -a "${SOURCE_DIR}/." "${INSTALL_DIR}/"
        # Remove things that shouldn't be in the install dir
        rm -rf "${INSTALL_DIR}/.git"
        # Preserve data/ if it exists; don't rm it
    fi
    ok "Files copied to ${INSTALL_DIR}."
fi

# =============================================================================
#  STEP 2 — CREATE DATA DIRECTORY
# =============================================================================
hdr "2 of 12 — Create data directory"
echo ""
note "The data directory holds the SQLite database, log files, and lock"
note "files. It needs to be writable by the PHP-FPM container."
echo ""
note "Permission note: The official php:fpm Docker image runs PHP workers"
note "as user 'www-data' (uid 33). On the FCOS host, uid 33 doesn't map"
note "to any named user. We use mode 770 with chown 33:33 (done in step 6"
note "after the installer creates the database)."
echo ""

mkdir -p "${DATA_DIR}"
ok "Data directory ready: ${DATA_DIR}"

# =============================================================================
#  STEP 3 — GENERATE ENCRYPTION KEY
# =============================================================================
hdr "3 of 12 — Generate AES-256 encryption key"
echo ""
note "The app encrypts your CenterEdge API credentials (username, password,"
note "API key, bearer token) at rest using AES-256-CBC. This key protects"
note "those credentials inside the SQLite database."
echo ""
note "The key is stored in ${ENV_FILE}"
note "This file is inside the app directory but is never served by Nginx"
note "(the Nginx config blocks access to everything except /public/)."
echo ""

if [[ -f "$ENV_FILE" ]] && grep -q "PG_ENCRYPTION_KEY=" "$ENV_FILE"; then
    ok "Encryption key already exists in ${ENV_FILE} — keeping it."
    note "(Good — re-running this script does not rotate your key.)"
else
    info "Generating 32-byte random key..."
    NEW_KEY=$(openssl rand -hex 32)
    # Write an environment file that all containers will load
    cat > "$ENV_FILE" <<ENVFILE
# pause-groups runtime environment
# This file is loaded by the PHP-FPM container and cron containers.
# Keep this file secure — it protects your CenterEdge credentials.

PG_ENCRYPTION_KEY=${NEW_KEY}
PG_APP_DEBUG=false
ENVFILE
    chmod 600 "$ENV_FILE"
    ok "Encryption key generated and saved to ${ENV_FILE} (mode 600)."
fi

# =============================================================================
#  STEP 4 — PULL PHP-FPM CONTAINER IMAGE
# =============================================================================
hdr "4 of 12 — Pull PHP-FPM container image"
echo ""
note "Image: ${PHP_IMAGE}"
note "This is the official PHP-FPM image from Docker Hub. It includes"
note "all required extensions (sqlite3, curl, mbstring, openssl)."
echo ""
note "This step may take 2–5 minutes on the first run (the image is"
note "~450 MB). Subsequent runs will use the locally cached image."
echo ""

info "Pulling image (this may take a few minutes)..."
if ! podman pull "${PHP_IMAGE}"; then
    die "Failed to pull ${PHP_IMAGE}.\n\n  Check:\n  1. Does the VM have outbound internet access?\n  2. Is Docker Hub reachable? (curl https://docker.io)\n  3. Is the image name correct? (${PHP_IMAGE})\n\n  If you are behind a proxy, configure it in /etc/containers/registries.conf"
fi
ok "Image ready: ${PHP_IMAGE}"

# Verify the image has the PHP extensions this app needs
info "Verifying required PHP extensions are in the image..."
MISSING_EXTS=()
for EXT in sqlite3 curl mbstring openssl pdo_sqlite; do
    if ! podman run --rm "${PHP_IMAGE}" php -m 2>/dev/null | grep -qi "^${EXT}$"; then
        MISSING_EXTS+=("$EXT")
    fi
done
if [[ ${#MISSING_EXTS[@]} -gt 0 ]]; then
    warn "The following PHP extensions are missing from the image: ${MISSING_EXTS[*]}"
    warn "The app may not work correctly. Consider using a custom PHP image"
    warn "that includes these extensions, or file a bug report."
else
    ok "All required PHP extensions present in image."
fi

# ── MSSQL driver overlay (Go-Kart Labor report) ──────────────────────────────
# The Go-Kart Labor page queries the CenterEdge MSSQL database, which needs
# the pdo_dblib PHP extension the stock image doesn't ship. Build a thin
# overlay image on top of ${PHP_IMAGE} and — because podman's image cache
# does NOT survive FCOS OS rebuilds — save it as a tar under /var/persist.
# The systemd unit reloads it from there after a rebuild (no network needed).
# If the build fails, the app still runs on the stock image; only the
# Go-Kart Labor report is affected. Re-run this script to retry.
MSSQL_IMAGE="localhost/pause-groups-fpm-mssql:latest"
MSSQL_TAR="${INSTALL_DIR}/php-fpm-mssql.tar"
RUNTIME_IMAGE="${PHP_IMAGE}"
if [[ -f "${SOURCE_DIR}/deploy/Containerfile.mssql" ]]; then
    echo ""
    info "Building the MSSQL driver overlay (pdo_dblib, for the Go-Kart Labor report)..."
    if podman build -f "${SOURCE_DIR}/deploy/Containerfile.mssql" \
            --build-arg BASE_IMAGE="${PHP_IMAGE}" \
            -t "${MSSQL_IMAGE}" "${SOURCE_DIR}"; then
        RUNTIME_IMAGE="${MSSQL_IMAGE}"
        info "Saving the built image to ${MSSQL_TAR} (survives OS rebuilds)..."
        if podman save -o "${MSSQL_TAR}.tmp" "${MSSQL_IMAGE}" && mv -f "${MSSQL_TAR}.tmp" "${MSSQL_TAR}"; then
            ok "MSSQL-enabled PHP image built and persisted."
        else
            rm -f "${MSSQL_TAR}.tmp"
            warn "Image built but could not be saved to ${MSSQL_TAR}."
            warn "After an FCOS OS rebuild the driver will be missing until this"
            warn "script is re-run. Check free space on /var/persist."
        fi
    else
        warn "MSSQL overlay build failed — continuing with the stock image."
        warn "Everything except the Go-Kart Labor report works normally."
        warn "Fix the build issue (usually network access to the distro package"
        warn "mirrors) and re-run this script."
    fi
fi

# =============================================================================
#  STEP 5 — RUN THE INTERACTIVE INSTALLER
# =============================================================================
hdr "5 of 12 — Run the interactive installer"
echo ""
note "The installer will initialize the SQLite database and walk you"
note "through creating your admin account."
echo ""
echo -e "${BOLD}  The installer will ask you these questions:${NC}"
echo ""
echo -e "  ${CYN}1. Username${NC}          Your admin login name (default: admin)"
echo -e "  ${CYN}2. Display name${NC}      Your name shown in the UI (default: Administrator)"
echo -e "  ${CYN}3. Password${NC}          Must be at least 8 characters (typed twice)"
echo -e "  ${CYN}4. Timezone${NC}          e.g. America/New_York — press Enter to accept default"
echo -e "  ${CYN}5. CenterEdge API?${NC}   You can say 'n' here and configure via the web UI later."
echo -e "                       If you say 'y', have ready:"
echo -e "                         • API Base URL   (e.g. https://your-centeredge-server/api)"
echo -e "                         • API Username"
echo -e "                         • API Password"
echo -e "                         • API Key (optional)"
echo ""
echo -e "${DIM}  Note: The installer will print cron and chown commands at the end."
echo -e "  Ignore those — this script handles both automatically.${NC}"
echo ""

if [[ -f "${DATA_DIR}/pause_groups.db" ]]; then
    info "Database already exists — the installer will skip user creation"
    info "and go straight to timezone + API config prompts."
    echo ""
fi

pause

info "Launching installer inside a temporary PHP container..."
echo ""

# Run install.php inside the official PHP container.
# --rm          removes the container when done
# -it           interactive terminal (needed for the prompts)
# --network host  shares the host network (needed if testing API connection)
# --env-file    loads PG_ENCRYPTION_KEY so credentials are encrypted correctly
# -v            mounts the app directory at the same path inside the container
#               (important: the path must match so DB_PATH in config.php is correct)
# -w            sets the working directory inside the container
podman run --rm -it \
    --network host \
    --env-file "${ENV_FILE}" \
    -v "${INSTALL_DIR}:${INSTALL_DIR}:z" \
    -w "${INSTALL_DIR}" \
    "${PHP_IMAGE}" \
    php install.php

echo ""
ok "Installer finished."

# =============================================================================
#  STEP 6 — FIX PERMISSIONS
# =============================================================================
hdr "6 of 12 — Fix file ownership"
echo ""
note "The installer ran as root (uid 0) inside the container. The PHP-FPM"
note "service (step 7) runs as www-data (uid 33) inside its container."
note "We chown the data directory to uid 33 so PHP-FPM can read/write it."
echo ""
note "Only the data/ directory is chowned to uid 33. App source files"
note "stay owned by root and are read-only to the container."
echo ""

chown -R 33:33 "${DATA_DIR}"
chmod 770 "${DATA_DIR}"
ok "data/ directory ownership set to uid 33:33 (www-data), mode 770."

# App files: root-owned, group-readable (PHP-FPM runs in container so
# this doesn't need to match the host www-data group — the container's
# uid 33 can read root:root files mounted with :z via world-read bits)
chmod -R o+rX "${INSTALL_DIR}"
chmod o-rX "${ENV_FILE}"   # env file stays private
ok "App files set to world-readable (required for container access)."

# =============================================================================
#  STEP 7 — CREATE PHP-FPM SYSTEMD SERVICE
# =============================================================================
hdr "7 of 12 — Create PHP-FPM systemd service"
echo ""
note "This creates a systemd service (pause-groups-fpm) that runs the"
note "PHP-FPM container as a long-lived process, restarting it if it"
note "crashes. PHP-FPM listens on port ${PHP_PORT} and handles all PHP"
note "execution for the web app."
echo ""
note "Nginx (already running) proxies incoming HTTP requests for this"
note "app to PHP-FPM on port ${PHP_PORT}. They communicate over localhost"
note "using the host network mode."
echo ""

# The unit content lives in deploy/write-fpm-unit.sh — shared with update.sh
# so the fresh-install and routine-update paths can never drift apart.
LOAD_TAR_ARG=""
[[ "$RUNTIME_IMAGE" == "$MSSQL_IMAGE" ]] && LOAD_TAR_ARG="$MSSQL_TAR"
bash "${SOURCE_DIR}/deploy/write-fpm-unit.sh" \
    "$ENV_FILE" "$INSTALL_DIR" "$RUNTIME_IMAGE" "$PHP_IMAGE" "$LOAD_TAR_ARG"

systemctl enable --now pause-groups-fpm

# Give it a moment to start up
info "Waiting for PHP-FPM to start..."
sleep 5

# Verify it's actually running and listening
if systemctl is-active --quiet pause-groups-fpm; then
    ok "pause-groups-fpm.service is active."
else
    warn "pause-groups-fpm.service does not appear to be active."
    warn "Check the logs: journalctl -eu pause-groups-fpm"
fi

# Check if the port is open
if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${PHP_PORT}" 2>/dev/null; then
    ok "PHP-FPM is accepting connections on port ${PHP_PORT}."
else
    warn "PHP-FPM is not yet responding on port ${PHP_PORT}."
    warn "It may still be starting. Check in a moment with:"
    warn "  systemctl status pause-groups-fpm"
    warn "  journalctl -eu pause-groups-fpm"
fi

# =============================================================================
#  STEP 8 — CREATE SYSTEMD TIMERS (replaces cron)
# =============================================================================
hdr "8 of 12 — Create systemd timers"
echo ""
note "Fedora CoreOS does not use /etc/cron.d in the traditional sense."
note "Instead, we use systemd timers — the modern equivalent of cron."
echo ""
note "Two timers are created:"
note "  • pause-groups-watchdog   fires every minute"
note "      Catches missed actions, enforces game states, re-queues"
note "      broken at-jobs, writes a heartbeat timestamp."
note "  • pause-groups-daily      fires every day at 00:05"
note "      Syncs the game list from CenterEdge, plans all scheduled"
note "      actions for the day, purges old data, rotates logs."
echo ""

# ── watchdog service ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/pause-groups-watchdog.service <<UNIT
[Unit]
Description=pause-groups watchdog (catches missed actions, enforces states)
# Don't run if FPM isn't up — the watchdog writes to the same DB
After=pause-groups-fpm.service

[Service]
Type=oneshot
# Run as uid 33 (www-data) so the container writes files owned by the
# same user as the FPM service, avoiding permission conflicts on the DB
ExecStart=/usr/bin/podman run --rm \\
    --network host \\
    --env-file ${ENV_FILE} \\
    -v ${INSTALL_DIR}:${INSTALL_DIR}:z \\
    -w ${INSTALL_DIR} \\
    -u 33:33 \\
    ${PHP_IMAGE} \\
    php cron_watchdog.php
StandardOutput=append:${DATA_DIR}/watchdog.log
StandardError=append:${DATA_DIR}/watchdog.log
UNIT

cat > /etc/systemd/system/pause-groups-watchdog.timer <<UNIT
[Unit]
Description=pause-groups watchdog — every minute

[Timer]
# Run every minute. Persistent=true means if the system was off at a
# scheduled time, it will run once when it comes back online.
OnCalendar=minutely
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# ── daily planner service ─────────────────────────────────────────────────────
# The unit content lives in deploy/write-daily-unit.sh — shared with update.sh
# so the fresh-install and routine-update paths can never drift apart. It runs
# on the SAME image as FPM (the pdo_dblib overlay when one was built): cron.php
# refreshes the venue-wide daily rollup from MSSQL every night, and the stock
# php:fpm image has no MSSQL driver to do it with.
# It also writes BOTH timers: the nightly one (pinned to the APP's timezone —
# on a UTC host running an Eastern venue an unpinned 00:05 fires at 20:05 the
# previous local evening, which costs the reporting rollups a whole extra day)
# and pause-groups-refresh.timer, the every-2h catch-up that gives the venue
# rollup more than one attempt per day.
bash "${SOURCE_DIR}/deploy/write-daily-unit.sh" \
    "$ENV_FILE" "$INSTALL_DIR" "$DATA_DIR" "$RUNTIME_IMAGE" "$LOAD_TAR_ARG"

# ── weekly podman image prune ────────────────────────────────────────────────
# Host maintenance rather than app logic, but it belongs to this install: the
# May 2026 incident was podman's overlay storage filling the 8 GB root
# partition and corrupting its own database. That prune was added by hand and
# so never existed on a rebuilt box. See deploy/write-prune-unit.sh.
bash "${SOURCE_DIR}/deploy/write-prune-unit.sh" "$DATA_DIR"

systemctl daemon-reload
systemctl enable --now pause-groups-watchdog.timer
systemctl enable --now pause-groups-daily.timer
systemctl enable --now pause-groups-refresh.timer
systemctl enable --now podman-prune.timer

# Verify
TIMERS_OK=1
for TIMER in pause-groups-watchdog.timer pause-groups-daily.timer pause-groups-refresh.timer podman-prune.timer; do
    if systemctl is-active --quiet "$TIMER"; then
        ok "${TIMER} is active."
    else
        warn "${TIMER} did not start — check: systemctl status ${TIMER}"
        TIMERS_OK=0
    fi
done
[[ $TIMERS_OK -eq 1 ]] && ok "Both timers running."

# =============================================================================
#  STEP 9 — SECURITY CLEANUP
# =============================================================================
hdr "9 of 12 — Remove fresh_install.php"
echo ""
note "fresh_install.php wipes the database and creates a default admin"
note "account with a known password (admin / admin123!). It must be"
note "deleted from production systems to prevent unauthorized access."
echo ""

FRESH="${INSTALL_DIR}/fresh_install.php"
if [[ -f "$FRESH" ]]; then
    rm -f "$FRESH"
    ok "fresh_install.php deleted."
else
    ok "fresh_install.php already absent — nothing to do."
fi

# =============================================================================
#  STEP 10 — GENERATE NGINX BLOCK
# =============================================================================
hdr "10 of 12 — Generate Nginx server block"
echo ""
note "This step does NOT modify ${NGINX_CONF}."
note "Instead, the required Nginx config block is written to a file and"
note "printed below so you can review and paste it yourself."
echo ""
note "Why manual? The existing Nginx config has working reverse-proxy"
note "rules for other services (Grafana, Tailscale, etc). Automatically"
note "patching a production config file risks breaking those services."
echo ""

# Write the block to a persistent file so it survives terminal scroll
cat > "${SNIPPET_FILE}" <<NGINXSNIPPET
# =============================================================================
# pause-groups Nginx server block
# Generated by setup-fcos.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
#
# Add this block to: ${NGINX_CONF}
# Placement: INSIDE the existing http { ... } block,
#            immediately before that http block's final closing brace.
#
# BEFORE APPLYING:
#   1. Set server_name to your server's actual hostname or IP address.
#      Currently set to: ${SERVER_NAME}
#      Examples:
#        server_name 192.168.1.50;
#        server_name pause.mycompany.local;
#        server_name _;   (catch-all — only use if no other vhost uses this)
#
#   2. After editing nginx.conf, TEST before reloading:
#        sudo podman exec systemd-nginx nginx -t
#      Only reload if the test passes:
#        sudo podman exec systemd-nginx nginx -s reload
# =============================================================================

# pause-groups — PHP arcade game scheduling app
# PHP-FPM runs as a separate container on port ${PHP_PORT} on localhost.
server {
    listen ${HTTP_PORT};
    server_name ${SERVER_NAME};

    # App files location
    root ${INSTALL_DIR};
    index index.php;

    # ── Security: block direct access to server-side files ──────────────────
    # These paths contain credentials, the database, internal docs (including
    # the security audit), the mock demo app, installers, or sensitive logic.
    # They must NEVER be served directly by Nginx. Regex locations match in
    # order, so these deny blocks sit BEFORE the .php fastcgi block below.
    # NOTE: routed API URLs (/api/health, /api/games, ...) are NOT files and
    # fall through to index.php — only direct hits on the api/*.php source
    # files are denied.
    location ~ ^/(data|lib|docs|demo)/ {
        deny all;
        return 404;
    }
    location ~ ^/api/.+\.php$ {
        deny all;
        return 404;
    }
    location ~ ^/(\.env|config\.php|cron\.php|cron_watchdog\.php|run_action\.php|install\.php|fresh_install\.php)$ {
        deny all;
        return 404;
    }
    location ~ \.md$ {
        deny all;
        return 404;
    }

    # ── Static assets ────────────────────────────────────────────────────────
    # CSS, JS, fonts — served directly by Nginx with caching headers.
    location /public/ {
        expires 1h;
        add_header Cache-Control "public, immutable";
    }

    # ── SPA / API router ─────────────────────────────────────────────────────
    # All other requests go to index.php, which handles both the single-page
    # app and the REST API (/api/...) routing.
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # ── PHP-FPM ──────────────────────────────────────────────────────────────
    # Forward PHP requests to the PHP-FPM container via TCP.
    # PHP-FPM listens on 127.0.0.1:${PHP_PORT} (started by pause-groups-fpm.service).
    location ~ \.php$ {
        include        fastcgi_params;
        fastcgi_pass   127.0.0.1:${PHP_PORT};
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        # Pass the real client IP through (useful if behind another proxy)
        fastcgi_param  REMOTE_ADDR     \$remote_addr;
    }

    # ── Block hidden files ───────────────────────────────────────────────────
    location ~ /\. {
        deny all;
    }
}
NGINXSNIPPET

ok "Nginx block saved to: ${SNIPPET_FILE}"
echo ""

# Show current Nginx server_name lines so the user knows what's already there
if [[ -f "${NGINX_CONF}" ]]; then
    info "Current Nginx config — existing server_name and listen lines:"
    echo ""
    grep -n "^\s*\(server_name\|listen\)" "${NGINX_CONF}" 2>/dev/null \
        | sed 's/^/    /' || echo "    (none found)"
    echo ""
    note "Use this to identify where to add the new block and whether"
    note "server_name or port conflicts exist before applying."
else
    warn "${NGINX_CONF} not found — is this the right path?"
fi

echo ""
echo -e "${BOLD}${YLW}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YLW}║  ACTION REQUIRED: Edit the Nginx config              ║${NC}"
echo -e "${BOLD}${YLW}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}1. Open the Nginx config in a text editor:${NC}"
echo -e "     ${CYN}nano ${NGINX_CONF}${NC}"
echo ""
echo -e "  ${BOLD}2. Scroll to the end and add the block from:${NC}"
echo -e "     ${CYN}cat ${SNIPPET_FILE}${NC}"
echo ""
echo -e "  ${BOLD}3. Update the server_name line${NC} (change from '${SERVER_NAME}' to"
echo -e "     your server's actual hostname or IP address)."
echo ""
echo -e "  ${BOLD}4. Test Nginx config (do this before reloading!):${NC}"
echo -e "     ${CYN}sudo podman exec systemd-nginx nginx -t${NC}"
echo ""
echo -e "  ${BOLD}5. Reload Nginx only if the test passes:${NC}"
echo -e "     ${CYN}sudo podman exec systemd-nginx nginx -s reload${NC}"
echo ""
note "The block has been saved to ${SNIPPET_FILE} and will"
note "survive FCOS rebuilds. You can view it any time with:"
note "  cat ${SNIPPET_FILE}"

# =============================================================================
#  STEP 11 — VERIFY SERVICES
# =============================================================================
hdr "11 of 12 — Verify services"
echo ""
info "Checking all pause-groups services and timers..."
echo ""

ALL_GOOD=1
printf "  %-45s" "pause-groups-fpm.service"
if systemctl is-active --quiet pause-groups-fpm; then
    echo -e "${GRN}active${NC}"
else
    echo -e "${RED}INACTIVE${NC} — run: journalctl -eu pause-groups-fpm"
    ALL_GOOD=0
fi

printf "  %-45s" "pause-groups-watchdog.timer"
if systemctl is-active --quiet pause-groups-watchdog.timer; then
    echo -e "${GRN}active${NC}"
else
    echo -e "${RED}INACTIVE${NC} — run: systemctl status pause-groups-watchdog.timer"
    ALL_GOOD=0
fi

printf "  %-45s" "pause-groups-daily.timer"
if systemctl is-active --quiet pause-groups-daily.timer; then
    echo -e "${GRN}active${NC}"
else
    echo -e "${RED}INACTIVE${NC} — run: systemctl status pause-groups-daily.timer"
    ALL_GOOD=0
fi

printf "  %-45s" "pause-groups-refresh.timer"
if systemctl is-active --quiet pause-groups-refresh.timer; then
    echo -e "${GRN}active${NC}"
else
    echo -e "${RED}INACTIVE${NC} — run: systemctl status pause-groups-refresh.timer"
    ALL_GOOD=0
fi

printf "  %-45s" "PHP-FPM port ${PHP_PORT}"
if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${PHP_PORT}" 2>/dev/null; then
    echo -e "${GRN}listening${NC}"
else
    echo -e "${YLW}not yet listening${NC} (may still be starting)"
    ALL_GOOD=0
fi

echo ""
if [[ $ALL_GOOD -eq 1 ]]; then
    ok "All services are running correctly."
else
    warn "One or more services need attention (see above)."
fi

# =============================================================================
#  STEP 12 — FINAL SUMMARY AND CHECKLIST
# =============================================================================
hdr "12 of 12 — Done!"
echo ""
echo -e "${BOLD}${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GRN}║  Installation complete                               ║${NC}"
echo -e "${BOLD}${GRN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}What was installed:${NC}"
echo "  App files    → ${INSTALL_DIR}"
echo "  Database     → ${DATA_DIR}/pause_groups.db"
echo "  Encrypt key  → ${ENV_FILE}  (keep this safe!)"
echo "  Backups      → ${BACKUP_DIR}/  (DB + key snapshots, 10 most recent)"
echo "  Nginx block  → ${SNIPPET_FILE}"
echo ""
echo -e "${BOLD}Services created:${NC}"
echo "  pause-groups-fpm.service       PHP-FPM on port ${PHP_PORT} (auto-restart)"
echo "  pause-groups-watchdog.timer    Every minute (missed action catch-up)"
echo "  pause-groups-daily.timer       Daily at 00:05 (game sync + planning)"
echo ""
echo -e "${BOLD}${YLW}Remaining manual steps (do these now):${NC}"
echo ""
echo -e "  ${BOLD}[ ] 1. Add the Nginx server block${NC}"
echo "        nano ${NGINX_CONF}"
echo "        Then paste the content from: ${SNIPPET_FILE}"
echo "        (Update server_name to your IP or hostname)"
echo ""
echo -e "  ${BOLD}[ ] 2. Test Nginx config${NC}"
echo "        sudo podman exec systemd-nginx nginx -t"
echo ""
echo -e "  ${BOLD}[ ] 3. Reload Nginx (only after test passes)${NC}"
echo "        sudo podman exec systemd-nginx nginx -s reload"
echo ""
echo -e "  ${BOLD}[ ] 4. Open the app in a browser${NC}"
echo "        http://<your-server-IP>/"
echo ""
echo -e "  ${BOLD}[ ] 5. Log in and configure CenterEdge API${NC} (if not done in installer)"
echo "        Settings → CenterEdge API → fill in URL, credentials → Save → Test"
echo ""
echo -e "  ${BOLD}[ ] 6. Create your first Pause Group${NC}"
echo "        Groups → New Group → add games or categories"
echo ""
echo -e "${BOLD}Useful commands for ongoing operation:${NC}"
echo ""
echo "  Check FPM status:       systemctl status pause-groups-fpm"
echo "  FPM logs:               journalctl -eu pause-groups-fpm"
echo "  Watchdog log:           tail -f ${DATA_DIR}/watchdog.log"
echo "  Daily cron log:         tail -f ${DATA_DIR}/cron.log"
echo "  App health endpoint:    curl http://localhost/api/health  (after Nginx is set up)"
echo "  Run watchdog manually:  systemctl start pause-groups-watchdog"
echo "  Run daily cron now:     systemctl start pause-groups-daily"
echo "  View timer schedule:    systemctl list-timers 'pause-groups*'"
echo ""
echo -e "${DIM}  Grafana continues to run on port 3000 — no conflict.${NC}"
echo -e "${DIM}  Tailscale VPN is unaffected.${NC}"
echo ""
