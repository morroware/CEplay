#!/usr/bin/env bash
# =============================================================================
#  write-prune-unit.sh — single source of truth for podman-prune.{service,timer}
# =============================================================================
#
#  Called by BOTH setup-fcos.sh (fresh install) and update.sh (routine
#  updates), the same arrangement write-fpm-unit.sh / write-daily-unit.sh /
#  write-bot-units.sh give the other units.
#
#  WHY THIS EXISTS AT ALL
#  ----------------------
#  Podman's overlay storage is what filled /dev/sda4 in the May 2026 incident
#  (docs/INCIDENT-2026-05-11.md): ~14 GB of layer data on an 8 GB partition,
#  which corrupted podman's own bookkeeping database and took every container
#  service down with it. A weekly prune was added by hand that day to stop it
#  recurring — and being hand-made, it was owned by nobody, absent from a
#  rebuild, and it sat FAILED for at least a week in September before anyone
#  noticed. Exactly the shape of failure the reporting rollup had just taught
#  us to design against, so it belongs in the repo like everything else.
#
#  WHY `image prune` AND NOT `system prune -af`
#  --------------------------------------------
#  The original hand-written command was `podman system prune -af --filter
#  until=168h`. Two problems, both measured on the venue Sep 2026:
#
#  1. `-a` removes every image no CONTAINER currently holds. The app's units
#     are Type=oneshot, so between runs nothing holds the stock php image —
#     and being the base layer of the pdo_dblib overlay did NOT protect it.
#     Observed: the prune deleted docker.io/library/php:8.3-fpm and the
#     watchdog re-pulled it from Docker Hub on its next firing (the pull shows
#     up in watchdog.log). That works, but it puts a weekly 500 MB download and
#     a Docker Hub dependency on the per-minute pause/unpause path — the one
#     job that must not need the internet. Without `-a`, only DANGLING images
#     are removed: the build leftovers from each update.sh overlay build, which
#     are the thing that actually accumulates.
#
#  2. `system prune` removes all stopped containers first, and this host
#     creates and auto-removes one every 60 seconds (the watchdog). A prune
#     enumerating containers while one disappears underneath it is the most
#     likely explanation for the exit-125 failure of 2026-08-31, which left no
#     journal trace. `image prune` never touches containers, so the race is
#     gone regardless of whether that diagnosis was right.
#
#  Volumes are deliberately NOT pruned. `podman system prune --volumes` is what
#  destroyed named volumes during the May recovery; nothing here should ever
#  reach for it.
#
#  WHY THE TIMER IS *NOT* TIMEZONE-PINNED (unlike the daily planner)
#  ----------------------------------------------------------------
#  write-daily-unit.sh pins the app's zone onto its OnCalendar because cron.php
#  computes "today" from it — a run landing on the previous local evening cost
#  every reporting figure an extra day. Nothing of the sort applies here: this
#  job deletes dangling layers and has no notion of a calendar day. The only
#  consequence of the host zone is which wall-clock hour it runs at, and a
#  dangling-layer prune is harmless at any hour. Left unpinned on purpose, so
#  the probe machinery isn't copied into a third writer for no benefit.
#
#  USAGE:
#    write-prune-unit.sh <data_dir>
#
#  Writes /etc/systemd/system/podman-prune.{service,timer} and daemon-reloads.
#  Does NOT enable/start the timer — callers decide when.

set -euo pipefail

DATA_DIR="${1:?usage: write-prune-unit.sh <data_dir>}"

# PG_PRUNE_UNIT_FILE override exists for tests; production callers leave it unset.
UNIT_FILE="${PG_PRUNE_UNIT_FILE:-/etc/systemd/system/podman-prune.service}"
UNIT_DIR="$(dirname "$UNIT_FILE")"
TIMER_FILE="${UNIT_DIR}/podman-prune.timer"

cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Prune unused Podman images (dangling build layers)

[Service]
Type=oneshot
# image prune, NOT system prune -af — see deploy/write-prune-unit.sh for why.
# No -a: that deletes the stock php image the watchdog runs on, forcing a
# weekly re-pull from Docker Hub on the safety-critical pause/unpause path.
ExecStart=/usr/bin/podman image prune -f --filter until=168h
# Its own log file, because the journal had NO entries for this unit's
# 2026-08-31 failure even though it retained a month of everything else — so
# a failure here must not depend on the journal to be diagnosable. This
# directory is the one proven to accept append: (cron.log/watchdog.log live
# here); /var/persist itself is refused with EACCES under SELinux.
StandardOutput=append:${DATA_DIR}/podman-prune.log
StandardError=append:${DATA_DIR}/podman-prune.log
UNIT
chmod 0644 "$UNIT_FILE"

cat > "$TIMER_FILE" <<TIMER
[Unit]
Description=Prune unused Podman images — weekly

# Persistent=true covers a box powered off at the scheduled time: it runs at
# the next boot instead of silently skipping a week.
#
# Deliberately NOT timezone-pinned — unlike pause-groups-daily.timer, nothing
# this job does depends on which calendar day it believes it is.

[Timer]
OnCalendar=Mon *-*-* 08:00:00
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
TIMER
chmod 0644 "$TIMER_FILE"

# The unit files are already written at this point; a daemon-reload hiccup
# shouldn't abort a caller mid-update. The next firing picks it up.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || echo "WARN: systemctl daemon-reload failed — run it manually" >&2
fi
echo "wrote ${UNIT_FILE} (podman image prune -f --filter until=168h)"
echo "wrote ${TIMER_FILE} (Mon 08:00, host clock)"
