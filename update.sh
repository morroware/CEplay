#!/usr/bin/env bash
# =============================================================================
#  update.sh — safe, idempotent update for the pause-groups app (Fedora CoreOS)
# =============================================================================
#
#  WHAT IT DOES (in order):
#    1. Backs up the database (a CONSISTENT snapshot) + the encryption key, and
#       records the currently-deployed git commit — into a timestamped folder
#       under /var/persist/pause-groups-backups/, and marks it as the latest
#       update so revert.sh can find it.
#    2. git pull in the source clone (/var/persist/pause-groups-src).
#    3. Syncs the new code into the live app dir, PRESERVING data/ and .env.
#    4. Removes install.php / fresh_install.php from the web root (security).
#    5. Runs the database migrations (idempotent, non-destructive).
#    6. Rebuilds the MSSQL driver overlay image (pdo_dblib for the Go-Kart
#       Labor report), persists it to /var/persist so FCOS OS rebuilds can't
#       drop it, and points the FPM unit at it. Skipped gracefully on failure.
#    7. Restarts PHP-FPM so the new code goes live, then health-checks.
#
#  Your database, users, API keys and encryption key are preserved. Safe to
#  re-run. If an update goes wrong, roll it back with:  sudo bash revert.sh
#
#  USAGE:  sudo bash update.sh
# =============================================================================

# --- Re-exec from a private copy -------------------------------------------
# The `git pull` below can rewrite THIS script mid-run (update.sh ships in the
# repo). Running from a temp copy makes the in-flight script immutable.
if [[ "${_PG_UPDATE_REEXEC:-}" != "1" ]]; then
    _self_copy="$(mktemp /tmp/pg-update.XXXXXX.sh)"
    cp -- "$0" "$_self_copy"
    export _PG_UPDATE_REEXEC=1
    exec bash "$_self_copy" "$@"
fi

set -euo pipefail

# --- Colours / helpers ------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
info() { echo -e "${BLU}[INFO]${NC}  $*"; }
ok()   { echo -e "${GRN}[OK]${NC}    $*"; }
warn() { echo -e "${YLW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
note() { echo -e "${DIM}         $*${NC}"; }
hdr()  { echo -e "\n${BOLD}── $* ${NC}"; }

trap 'echo -e "\n${RED}update.sh failed at line $LINENO.${NC} Your app was not left half-updated by design:\n  • The backup was taken first — restore it with:  sudo bash revert.sh\n  • Re-run once the cause is fixed (this script is idempotent)." >&2' ERR

# --- Configuration (matches setup-fcos.sh) ---------------------------------
INSTALL_DIR="/var/persist/pause-groups"
SRC_DIR="/var/persist/pause-groups-src"
DATA_DIR="${INSTALL_DIR}/data"
ENV_FILE="${INSTALL_DIR}/.env"
DB_FILE="${DATA_DIR}/pause_groups.db"
BACKUP_ROOT="/var/persist/pause-groups-backups"
LATEST_MARKER="${BACKUP_ROOT}/LATEST_UPDATE"
FPM_SERVICE="pause-groups-fpm"
KEEP_BACKUPS=15

# Detect the operator's chosen PHP version from the installed FPM unit.
# Units written by deploy/write-fpm-unit.sh record it in a BASE_PHP_IMAGE
# comment (the ExecStart image may be the MSSQL overlay tag); older units
# name the stock image directly. Fall back to the setup-fcos.sh default.
PHP_IMAGE="$(grep -oE '^# BASE_PHP_IMAGE=\S+' \
    /etc/systemd/system/${FPM_SERVICE}.service 2>/dev/null | head -1 | cut -d= -f2 || true)"
if [[ -z "$PHP_IMAGE" ]]; then
    PHP_IMAGE="$(grep -ohE 'docker.io/library/php:[0-9.]+-fpm' \
        /etc/systemd/system/${FPM_SERVICE}.service 2>/dev/null | head -1 || true)"
fi
PHP_IMAGE="${PHP_IMAGE:-docker.io/library/php:8.3-fpm}"

echo -e "${BOLD}${GRN}pause-groups — update${NC}"
echo "  App:    ${INSTALL_DIR}"
echo "  Source: ${SRC_DIR}"
echo "  Image:  ${PHP_IMAGE}"
echo ""

# --- Pre-flight -------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Must run as root:  sudo bash update.sh"
command -v podman &>/dev/null || die "podman not found (expected on Fedora CoreOS)."
[[ -d "$SRC_DIR/.git" ]] || die "Source clone not found at ${SRC_DIR}. Clone the repo there first (see INSTALL-FCOS.md)."
[[ -d "$INSTALL_DIR" ]] || die "App dir ${INSTALL_DIR} missing. Run setup-fcos.sh for a first-time install."
[[ -f "$DB_FILE" ]] || die "No database at ${DB_FILE}. Run setup-fcos.sh for a first-time install."
systemctl list-unit-files "${FPM_SERVICE}.service" &>/dev/null \
    || die "${FPM_SERVICE} is not installed. Run setup-fcos.sh for a first-time install."

# Refuse to pull over uncommitted local edits — they'd be lost or cause a
# merge conflict. Let the operator resolve them deliberately.
if [[ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]]; then
    die "Source clone has uncommitted local changes. Review 'git -C ${SRC_DIR} status', commit/stash/discard them, then re-run."
fi
BRANCH="$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
    die "Source clone is on a detached commit (left by a previous revert?). Run:  git -C ${SRC_DIR} checkout main   then re-run update.sh."
fi
FROM_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"

# =============================================================================
#  1. Backup (BEFORE anything changes)
# =============================================================================
hdr "1/8  Backup database + key"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BK="${BACKUP_ROOT}/update-${STAMP}"
mkdir -p "$BK"

# Consistent single-file DB snapshot via SQLite VACUUM INTO, run in the PHP
# container (the FCOS host has no sqlite3 CLI). This reads a consistent view of
# the live WAL database — unlike a plain cp, it can't miss the last commit.
snapped=0
if podman image exists "$PHP_IMAGE" 2>/dev/null; then
    if podman run --rm --network none \
            -v "${INSTALL_DIR}:${INSTALL_DIR}:z" \
            -v "${BACKUP_ROOT}:${BACKUP_ROOT}:z" \
            "$PHP_IMAGE" \
            php -r '$s=new SQLite3($argv[1]); $s->busyTimeout(60000); $s->exec("VACUUM INTO ".chr(39).$argv[2].chr(39)); $s->close();' \
            "$DB_FILE" "${BK}/pause_groups.db" 2>/dev/null; then
        snapped=1
        ok "Consistent DB snapshot written (VACUUM INTO)."
    fi
fi
if [[ $snapped -eq 0 ]]; then
    warn "VACUUM snapshot unavailable; copying the DB files instead."
    cp -a "$DB_FILE" "${BK}/pause_groups.db"
    if [[ -f "${DB_FILE}-wal" ]]; then cp -a "${DB_FILE}-wal" "${BK}/pause_groups.db-wal"; fi
    if [[ -f "${DB_FILE}-shm" ]]; then cp -a "${DB_FILE}-shm" "${BK}/pause_groups.db-shm"; fi
fi
if [[ -f "$ENV_FILE" ]]; then cp -a "$ENV_FILE" "${BK}/env.bak"; fi
# Record what was deployed so revert.sh can restore both DB AND code.
printf '%s\n' "$FROM_SHA" > "${BK}/deployed_commit.txt"
{
    echo "created_utc=${STAMP}"
    echo "branch=${BRANCH}"
    echo "from_commit=${FROM_SHA}"
    echo "php_image=${PHP_IMAGE}"
} > "${BK}/manifest.txt"
chmod -R go-rwx "$BK" || true
printf '%s\n' "$BK" > "$LATEST_MARKER"
ok "Backup: ${BK}"
note "Deployed commit recorded: ${FROM_SHA:0:12}"

# Prune old update backups (keep newest KEEP_BACKUPS).
mapfile -t _old < <(ls -1dt "${BACKUP_ROOT}"/update-*/ 2>/dev/null || true)
if (( ${#_old[@]} > KEEP_BACKUPS )); then
    for (( i=KEEP_BACKUPS; i<${#_old[@]}; i++ )); do rm -rf "${_old[$i]}"; done
    note "Pruned old update backups (kept ${KEEP_BACKUPS})."
fi

# =============================================================================
#  2. Pull
# =============================================================================
hdr "2/8  git pull (${BRANCH})"
pulled=0
for attempt in 1 2 3 4; do
    if git -C "$SRC_DIR" pull --ff-only 2>&1; then pulled=1; break; fi
    warn "pull failed (attempt ${attempt}); retrying..."; sleep $((2**attempt))
done
[[ $pulled -eq 1 ]] || die "git pull failed. If the branch diverged, reconcile it manually, then re-run."
TO_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [[ "$TO_SHA" == "$FROM_SHA" ]]; then
    info "Already up to date (${TO_SHA:0:12}). Re-syncing anyway to be safe."
else
    ok "Updated ${FROM_SHA:0:12} → ${TO_SHA:0:12}"
fi

# --- Hand off to a newer update.sh if this pull delivered one ---------------
# We run from a temp copy of the script (see the re-exec at the top), so a
# pull that changes update.sh itself would otherwise only take effect on the
# NEXT run — new update steps would silently not happen this time. Detect
# that and exec the freshly pulled version from the top. It re-runs the
# backup and pull (both idempotent) and then continues with the new logic.
# The chain guard allows exactly one hand-off, so two script versions can
# never ping-pong.
if [[ "${_PG_UPDATE_CHAIN:-0}" -lt 1 ]] && [[ -f "${SRC_DIR}/update.sh" ]] \
        && ! cmp -s "$0" "${SRC_DIR}/update.sh"; then
    info "This update delivered a newer update.sh — handing off to it now..."
    _next_copy="$(mktemp /tmp/pg-update.XXXXXX.sh)"
    cp -- "${SRC_DIR}/update.sh" "$_next_copy"
    export _PG_UPDATE_CHAIN=$(( ${_PG_UPDATE_CHAIN:-0} + 1 ))
    export _PG_UPDATE_REEXEC=1
    exec bash "$_next_copy" "$@"
fi

# =============================================================================
#  3. Sync code into the live app dir (preserving data/ and .env)
# =============================================================================
hdr "3/8  Sync app files"
if command -v rsync &>/dev/null; then
    rsync -a --delete --exclude='.git/' --exclude='data/' --exclude='.env' \
        "${SRC_DIR}/" "${INSTALL_DIR}/"
else
    cp -a "${SRC_DIR}/." "${INSTALL_DIR}/"
    rm -rf "${INSTALL_DIR}/.git"
fi
ok "App files synced (data/ and .env untouched)."

# =============================================================================
#  4. Security cleanup — never leave installers in the web root
# =============================================================================
hdr "4/8  Remove installers from web root"
for f in install.php fresh_install.php; do
    if [[ -f "${INSTALL_DIR}/${f}" ]]; then rm -f "${INSTALL_DIR}/${f}"; ok "Removed ${f}"; fi
done

# --- Fix ownership (data writable by the container's uid 33) ---------------
chown -R 33:33 "$DATA_DIR"; chmod 770 "$DATA_DIR"
chmod -R o+rX "$INSTALL_DIR"
[[ -f "$ENV_FILE" ]] && chmod o-rX "$ENV_FILE" || true

# =============================================================================
#  5. Run database migrations (idempotent, non-destructive)
# =============================================================================
hdr "5/8  Migrate database"
# DB::getInstance() runs CREATE TABLE IF NOT EXISTS + the ALTER/data migrations.
podman run --rm --network host \
    --env-file "$ENV_FILE" \
    -v "${INSTALL_DIR}:${INSTALL_DIR}:z" \
    -w "$INSTALL_DIR" -u 33:33 \
    "$PHP_IMAGE" \
    php -r 'require "config.php"; require "lib/db.php"; DB::getInstance(); fwrite(STDERR, "schema-ok\n");' \
    && ok "Schema migrated." || die "Migration step failed — restore with: sudo bash revert.sh"

# =============================================================================
#  6. MSSQL driver overlay (Go-Kart Labor report)
# =============================================================================
hdr "6/8  MSSQL driver overlay + historical backfill"
# Rebuild the pdo_dblib overlay on the operator's PHP base so the Go-Kart
# Labor report can reach the CenterEdge MSSQL database. The built image is
# persisted to /var/persist (podman's cache does NOT survive FCOS OS
# rebuilds) and the FPM unit is rewritten via the shared unit writer.
# On any failure the unit is left untouched: a service already running the
# overlay keeps its tar, and a stock-image service stays stock — the app
# works either way, only the Labor report needs the driver.
MSSQL_IMAGE="localhost/pause-groups-fpm-mssql:latest"
MSSQL_TAR="${INSTALL_DIR}/php-fpm-mssql.tar"
#
# The DAILY unit is rewritten alongside FPM. cron.php refreshes the venue-wide
# daily rollup (venue_daily_stats — the year-over-year card and the Analytics
# deep-history view) from MSSQL every night, so it needs the driver too. While
# only FPM got the overlay, that refresh threw "No MSSQL PDO driver is
# installed in this PHP runtime" every night and the rollup silently froze at
# whatever day the last one-time backfill had written. The per-minute watchdog
# stays on the stock image on purpose: it never touches MSSQL.
if [[ -f "${SRC_DIR}/deploy/Containerfile.mssql" && -f "${SRC_DIR}/deploy/write-fpm-unit.sh" ]]; then
    info "Building the pdo_dblib overlay on ${PHP_IMAGE} (first run takes a minute or two)..."
    if podman build -f "${SRC_DIR}/deploy/Containerfile.mssql" \
            --build-arg BASE_IMAGE="${PHP_IMAGE}" \
            -t "${MSSQL_IMAGE}" "${SRC_DIR}"; then
        if podman save -o "${MSSQL_TAR}.tmp" "${MSSQL_IMAGE}" && mv -f "${MSSQL_TAR}.tmp" "${MSSQL_TAR}"; then
            ok "Overlay built and persisted to ${MSSQL_TAR}."
            bash "${SRC_DIR}/deploy/write-fpm-unit.sh" \
                "$ENV_FILE" "$INSTALL_DIR" "$MSSQL_IMAGE" "$PHP_IMAGE" "$MSSQL_TAR"
            ok "FPM unit points at the MSSQL-enabled image."
            if [[ -f "${SRC_DIR}/deploy/write-daily-unit.sh" ]]; then
                bash "${SRC_DIR}/deploy/write-daily-unit.sh" \
                    "$ENV_FILE" "$INSTALL_DIR" "$DATA_DIR" "$MSSQL_IMAGE" "$MSSQL_TAR"
                ok "Nightly planner unit points at the MSSQL-enabled image."
                # The writer also (re)writes both timers: the nightly one with
                # the APP's timezone pinned, and the every-2h reporting
                # catch-up. Enable the catch-up here — installs that predate it
                # have the unit on disk now but nothing starting it, and it is
                # the thing that stops one missed night costing a whole day of
                # reporting.
                systemctl daemon-reload 2>/dev/null || true
                if systemctl enable --now pause-groups-refresh.timer >/dev/null 2>&1; then
                    ok "Reporting catch-up timer enabled (every 2h)."
                else
                    warn "Could not enable pause-groups-refresh.timer — check: systemctl status pause-groups-refresh.timer"
                fi
                # Restart the nightly timer so a rewritten schedule (e.g. the
                # timezone pin) takes effect now rather than after a reboot.
                systemctl restart pause-groups-daily.timer 2>/dev/null || true
                note "Reporting rollups now refresh through the day, on venue-local time."
            fi
        else
            rm -f "${MSSQL_TAR}.tmp"
            warn "Overlay built but could not be saved to ${MSSQL_TAR} (disk space?)."
            warn "Unit left unchanged — re-run update.sh after freeing space."
        fi
    else
        warn "Overlay build failed — unit left unchanged; the app still runs."
        warn "Everything except the Go-Kart Labor report works without it."
        warn "Fix the build issue (usually package-mirror access) and re-run."
    fi
else
    note "deploy/Containerfile.mssql not in source tree — skipping."
fi

# Seed the one-time historical backfills NOW (best-effort) so the deep history —
# guest new-vs-returning, multi-year Performance trends, ticket trends — shows up
# right after this update instead of waiting for tonight's cron. Idempotent and
# flag-guarded (Scheduler::runPendingBackfills): if it can't finish, or MSSQL
# isn't reachable, cron simply retries later, so this NEVER fails the update.
# Uses the pdo_dblib overlay image when available (loading it from the persisted
# tar if needed); the first run can take a few minutes over ~20 years of data.
BACKFILL_IMAGE="$PHP_IMAGE"
if podman image exists "$MSSQL_IMAGE" 2>/dev/null; then
    BACKFILL_IMAGE="$MSSQL_IMAGE"
elif [[ -f "$MSSQL_TAR" ]] && podman load -i "$MSSQL_TAR" &>/dev/null; then
    BACKFILL_IMAGE="$MSSQL_IMAGE"
fi
info "Seeding historical backfills from MSSQL (one-time; the first run can take a few minutes)..."
if podman run --rm --network host \
        --env-file "$ENV_FILE" \
        -v "${INSTALL_DIR}:${INSTALL_DIR}:z" \
        -w "$INSTALL_DIR" -u 33:33 \
        "$BACKFILL_IMAGE" \
        php run_backfills.php; then
    ok "Historical backfills finished (or safely skipped)."
else
    warn "Historical backfills didn't finish — cron will retry tonight. (Non-fatal.)"
fi

# =============================================================================
#  7. Slack bot timers (birthdays, work anniversaries)
# =============================================================================
hdr "7/8  Slack bot timers"
#
# Both bots read the employee roster out of MSSQL, so their units have to point
# at the pdo_dblib overlay — the same lesson as the daily planner unit above,
# which spent six weeks pinned to the stock image and silently failing.
#
# THE SERVICE UNIT IS REFRESHED EVERY DEPLOY; THE TIMER IS NOT TOUCHED once it
# exists. The service carries the install path and the image, so it goes stale.
# The timer carries only the schedule — the time an operator chose during
# install.sh — and rewriting that on every update would quietly move the
# posting time back to a default. See deploy/write-bot-units.sh.
#
# A timer is only ENABLED for a bot that is actually set up (a Slack token and
# a channel, checked with --is-configured, which touches no network). Enabling
# one for a bot nobody configured would put a failed run and an audit row in
# front of the operator every morning.
# ── weekly podman image prune ────────────────────────────────────────────────
# Written on EVERY deploy, and deliberately outside the overlay-build branch
# above: it runs plain `podman`, needs no image, and its whole purpose is
# keeping podman's own storage from filling the root partition the way it did
# in May 2026. Refreshing it here is also what corrects the original
# hand-written `system prune -af`, which deleted the watchdog's image weekly
# and raced the per-minute container churn. See deploy/write-prune-unit.sh.
if [[ -f "${SRC_DIR}/deploy/write-prune-unit.sh" ]]; then
    bash "${SRC_DIR}/deploy/write-prune-unit.sh" "$DATA_DIR"
    if systemctl enable --now podman-prune.timer >/dev/null 2>&1; then
        ok "Weekly podman image prune installed and enabled."
    else
        warn "Could not enable podman-prune.timer — check: systemctl status podman-prune.timer"
    fi
    # A hand-made drop-in from the September 2026 debugging session pointed the
    # log at /var/persist, which SELinux refuses (the unit then dies at
    # 209/STDOUT before podman runs). The unit now carries its own logging, so
    # the drop-in is redundant at best and breaks the unit at worst.
    if [[ -f /etc/systemd/system/podman-prune.service.d/10-logging.conf ]]; then
        rm -f /etc/systemd/system/podman-prune.service.d/10-logging.conf
        rmdir /etc/systemd/system/podman-prune.service.d 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        note "Removed the superseded podman-prune logging drop-in."
    fi
fi

BOT_IMAGE="$PHP_IMAGE"
if podman image exists "$MSSQL_IMAGE" 2>/dev/null; then
    BOT_IMAGE="$MSSQL_IMAGE"
elif [[ -f "$MSSQL_TAR" ]] && podman load -i "$MSSQL_TAR" &>/dev/null; then
    BOT_IMAGE="$MSSQL_IMAGE"
fi

if [[ ! -f "${SRC_DIR}/deploy/write-bot-units.sh" ]]; then
    note "deploy/write-bot-units.sh not in source tree — skipping bot timers."
elif [[ "$BOT_IMAGE" != "$MSSQL_IMAGE" ]]; then
    warn "The pdo_dblib overlay isn't available, and the bots need it to read the"
    warn "roster. Leaving their units alone — re-run update.sh once the overlay builds."
else
    for bot in birthdays anniversaries; do
        case "$bot" in
            birthdays)     bot_script="birthdays/birthday_bot.php";        bot_label="Birthdays" ;;
            anniversaries) bot_script="anniversaries/anniversary_bot.php"; bot_label="Work Anniversaries" ;;
        esac
        [[ -f "${INSTALL_DIR}/${bot_script}" ]] || continue

        timer="ceplay-${bot}.timer"
        had_timer=no
        [[ -f "/etc/systemd/system/${timer}" ]] && had_timer=yes

        configured=no
        if podman run --rm --network host --env-file "$ENV_FILE" \
                -v "${INSTALL_DIR}:${INSTALL_DIR}:z" -w "$INSTALL_DIR" -u 33:33 \
                "$BOT_IMAGE" php "$bot_script" --is-configured &>/dev/null; then
            configured=yes
        fi

        # Nothing set up and no timer installed: say how, and move on. Writing
        # units for a bot the venue may not want is noise at best.
        if [[ "$configured" == "no" && "$had_timer" == "no" ]]; then
            note "${bot_label} bot: not configured — add a Slack token and channel on the"
            note "  ${bot_label} page, then re-run this script (or sudo bash ${bot}/install.sh)."
            continue
        fi

        bash "${SRC_DIR}/deploy/write-bot-units.sh" \
            "$bot" "$ENV_FILE" "$INSTALL_DIR" "$DATA_DIR" "$MSSQL_IMAGE" "$MSSQL_TAR" >/dev/null \
            && ok "${bot_label} bot units refreshed." \
            || warn "${bot_label} bot units could not be written."

        if [[ "$configured" == "yes" ]]; then
            if systemctl is-enabled --quiet "$timer" 2>/dev/null; then
                systemctl restart "$timer" 2>/dev/null || true
                ok "  ${timer} already enabled — schedule preserved."
            else
                if systemctl enable --now "$timer" >/dev/null 2>&1; then
                    ok "  ${timer} enabled."
                    note "  Posting time is the default; change it with: sudo bash ${bot}/install.sh"
                else
                    warn "  Could not enable ${timer} — check: systemctl status ${timer}"
                fi
            fi
        else
            note "  ${bot_label} bot has a timer but no Slack token/channel — left as-is."
        fi
    done
fi

# =============================================================================
#  8. Restart + health check
# =============================================================================
hdr "8/8  Restart + verify"
systemctl restart "$FPM_SERVICE"
sleep 4
if systemctl is-active --quiet "$FPM_SERVICE"; then ok "${FPM_SERVICE} is active."; else warn "${FPM_SERVICE} not active — check: journalctl -eu ${FPM_SERVICE}"; fi

resp="$(curl -s --max-time 6 http://localhost/api/health 2>/dev/null || true)"
if echo "$resp" | grep -q '"database":true'; then
    ok "App responding, database OK."
else
    warn "Health check inconclusive (app may still be warming up, or Nginx not set up)."
    note "Response: ${resp:-<none>}"
fi

echo ""
echo -e "${BOLD}${GRN}Update complete.${NC}"
echo "  ${FROM_SHA:0:12} → ${TO_SHA:0:12}"
echo "  Backup:   ${BK}"
echo "  Roll back this update:   sudo bash revert.sh"
echo ""
note "In the browser, hard-refresh (Ctrl+Shift+R / Cmd+Shift+R) to pick up new"
note "CSS/JS — /public assets are cached for up to 1 hour."
