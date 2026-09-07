# Castle Fun Center - Pause Group Automation

## Project Overview
Self-hosted, framework-free pause-group automation for Castle Fun Center (arcade/entertainment venue). Automates pausing/unpausing of CenterEdge games AND kiosks via recurring time windows, overrides, manual actions, and multi-tier enforcement. Pause groups can mix games and kiosks; kiosks also have a standalone management page.

## Architecture
- **Backend:** Pure PHP 7.4+ (no Composer, no frameworks). SQLite database with WAL mode.
- **Frontend:** Vanilla JavaScript SPA with hash-based routing. No build step, no npm.
- **External API:** CenterEdge Card System API (REST, SHA-1 auth, bearer token caching).

## Key Files
- `index.php` — Main router: SPA shell, API dispatch, safety nets (Tier 1/2 enforcement)
- `config.php` — Constants: encryption key, DB path, session lifetime, API timeouts
- `cron.php` — Daily cron (00:05 **app-local**, see Scheduling Engine): game sync, plan day, queue `at` jobs, nightly DB backup (`data/backups/`, VACUUM INTO, keep 14), rollup, purge old data. Then `cronRefreshReporting()` — the venue daily rollup refresh + one-time MSSQL backfills — which is LOCK-FREE and runs on EVERY firing, including one that skipped the plan because the watchdog held the scheduler lock, or whose plan threw. Do not fold it back inside the lock or behind the plan's success: that made it one unretried attempt per day, and every miss cost a full day of reporting. **Every step now has its OWN try/catch** — steps 2-4 (replay missed actions / plan the day / queue `at` jobs) were the only ones without, so a throw in any of them (`executeMissedActions` calls the CenterEdge API, so a slow card system suffices) aborted all eight steps and left `pause-groups-daily.service` in systemd's `failed` state until the next night. Failures set `$planFailed`, are recorded to `action_log` via `cronStepFailed()` (source `cron`, action `plan_day`, with the step name — so an INTERMITTENT nightly failure is diagnosable after the fact), and the run still exits non-zero at the END so the unit stays visibly failed
- `cron_watchdog.php` — Per-minute watchdog: missed actions, state enforcement, re-queue
- `deploy/write-prune-unit.sh` — Writes `podman-prune.{service,timer}` (weekly `podman image prune -f --filter until=168h`), called by `setup-fcos.sh` and `update.sh` like every other unit writer. It guards the failure mode of `docs/INCIDENT-2026-05-11.md` — podman's overlay storage filling the 8 GB root partition and corrupting its own database. **`image prune`, never `system prune -af`:** `-a` deletes `php:8.3-fpm` (being the overlay's base layer does NOT protect it — measured), which the per-minute watchdog then re-pulls from Docker Hub, putting a weekly network dependency on the safety-critical pause/unpause path; and `system prune` removes stopped containers first, racing the watchdog's once-a-minute `--rm` container (the likeliest cause of the exit-125 failure on 2026-08-31, which left no journal trace). Volumes are NEVER pruned — that is what destroyed named volumes during the May recovery. It logs to `data/podman-prune.log` rather than the journal, and its timer is deliberately NOT timezone-pinned: unlike the daily planner, nothing it does depends on which calendar day it thinks it is
- `print_timezone.php` — Prints the APP's timezone and nothing else, for the deploy scripts. `deploy/write-daily-unit.sh` asks it which clock "00:05" means, exactly as the two Slack bot installers ask their runners `--print-timezone`. Falls back to `DEFAULT_TIMEZONE` rather than failing, and validates the stored value before printing (a junk zone yields a timer systemd silently refuses to load — the exact failure the pin exists to prevent)
- `run_action.php` — Single-action executor invoked by `at` jobs
- `backfill_card_activity.php` — OPTIONAL manual runner (thin wrapper over `Scheduler::backfillCardActivityFromMssql()`). The nightly `cron.php` runs this backfill **automatically, once** (guarded by config flag `card_activity_backfill_done`, lock-free after the main plan) as soon as it runs with MSSQL configured — no CLI needed. It seeds the guest ledger (`card_activity`) from MSSQL `PlayerCardTrans` (MIN/MAX `TransDateTime` per card) so "new vs returning" reaches back ~2 decades instead of only the 30-day feed. Batched by year; idempotent (reuses the nightly rollup's monotonic UPSERT — only widens); venue server only
- `run_backfills.php` — Runs whichever one-time MSSQL backfills are still pending (guest ledger + per-game play history) on demand via `Scheduler::runPendingBackfills()` — the single home for the flag-guard logic, shared with `cron.php`. `update.sh` invokes it after a deploy (best-effort, using the pdo_dblib overlay image) so the deep history appears immediately instead of at the next nightly cron; also runnable by hand. Idempotent/flag-guarded, so running early just means cron finds it done
- `run.sh` — **The way to run ANY app CLI script on the venue.** There is NO `php` on the venue host (nor `sqlite3`) — the app runs entirely in containers — so every "Usage: php foo.php" line is unfollowable as written, and `php run_backfills.php` just answers `command not found`. This wrapper picks the pdo_dblib overlay image (loading it back from `php-fpm-mssql.tar` if an OS rebuild dropped it), mounts the install dir, and runs as `www-data` (33:33) so nothing in `data/` ends up root-owned and breaks the web tier. It also pins `-w` to the INSTALL dir (`/var/persist/pause-groups`), which matters because the git checkout is a DIFFERENT directory (`/var/persist/pause-groups-src`) with its own empty `data/` — running a script from there silently reads the wrong database. Same shape as `birthdays/run.sh`. Usage: `sudo bash /var/persist/pause-groups/run.sh check_rollups.php`
- `check_rollups.php` — "Is the reporting history actually advancing?" Row counts + coverage windows for `venue_daily_stats`, `game_daily_stats`, `game_hourly_stats` and the raw feed, then a plain verdict on the first: EMPTY (backfill never ran → any range past the raw feed reads as ZERO), STALE (the job stopped, or the POS is missing days the venue worked), QUIET VENUE (the refresh is current and nobody swiped — nothing to fix), or HEALTHY. Tolerance 3 days, matching the yoy card and the Analytics deep banner — the rollup never holds today and refreshes at 00:05 UTC (20:05 local), so 1 day behind is normal and must not read as a fault. The verdict comes from the same `Reporting::rollupHealth()` the pages use, so the CLI and the dashboard can never disagree, and it PRINTS ITS EVIDENCE (when the refresh last ran and through what day, the days it covered but found empty, and how many plays the app's own feed saw on them) rather than only its conclusion. This is the first thing to run when someone says a reporting page "looks broken" on Month/Year
- `lib/scheduler.php` — Core scheduling engine (plan, execute, enforce, resolve conflicts)
- `lib/centeredge_client.php` — CenterEdge API client (auth, games, kiosks, capabilities, pagination, retry)
- `lib/db.php` — SQLite singleton, schema init, query helpers (`:p0` positional params)
- `lib/auth.php` — Session management (bcrypt, HttpOnly, SameSite, 2h timeout, rate limiting). Login rate-limit/audit key off `getClientIp()` (`api/auth.php`), which trusts `X-Forwarded-For` only from a loopback reverse proxy and then takes the RIGHTMOST (proxy-appended) hop — the client-supplied leftmost entries are never trusted, so the lockout can't be bypassed by rotating a spoofed IP.
- `lib/csrf.php` — CSRF token generation + timing-safe validation
- `lib/crypto.php` — AES-256-CBC encrypt-then-MAC (HMAC-SHA256, backward-compatible)
- `lib/validator.php` — Input validation (strings, ints, dates, times, enums, arrays)
- `lib/mssql_client.php` — READ-ONLY CenterEdge MSSQL client for the reporting pages (Labor/Card Loads/Ticket Trends/Revenue Mix + the Database Explorer). Single-SELECT guard (`assertReadOnly`), regex-validated `:from`/`:to` / `:date` range binding, driver detection (pdo sqlsrv → dblib → odbc), settable timeout. Connection config lives encrypted in `api_config`
- `lib/reporting.php` — `Reporting` class: the set of game IDs that count as "redemption" for payout math (`redemptionGameIds`, resolved from games/categories), shared across the analytics/games endpoints. NOTE: the Day/Week/Month/Year/Custom window model (`perfResolveWindow`/`perfRangeMeta`/`perfTimezone`) lives in `api/analytics.php`, which the MSSQL report handlers `require_once` and reuse

## Directory Layout
```
api/          — API endpoint handlers (auth, settings, games, cards, groups, reader_groups, promotions, items, kiosks, schedules, overrides, analytics, labor, cardloads, tickets, revenue, redemption, explorer, birthdays, anniversaries, logs, users, roles, capabilities)
lib/          — 13 core libraries (db, auth, csrf, crypto, validator, scheduler, centeredge_client, mssql_client, reporting, birthday_config, anniversary_config, today_cache, roster_guard)
public/js/    — Vanilla JS modules (api, app, login, dashboard, games, tags, cards, groups, kiosks, schedules, overrides, analytics, performance, readers, promotions, items, labor, cardloads, tickets, revenue, redemption, explorer, birthdays, anniversaries, logs, settings)
public/       — Also: manifest.webmanifest + sw.js + icons/ (the PWA layer; index.php serves sw.js/manifest at the app ROOT so the worker scope covers the whole app)
public/css/   — Dark/light theme stylesheet (modular @imports from style.css; page styles under css/pages/)
data/         — Runtime: SQLite DB, locks, heartbeats, logs, nightly backups (gitignored)
birthdays/    — Staff birthday Slack bot: CLI runner + installer + systemd timer (runs from a timer, configured from the Birthdays page)
anniversaries/ — Staff WORK-ANNIVERSARY Slack bot: the same shape, keyed off hire date instead of birth date (configured from the Work Anniversaries page). Shares birthdays/lib/slack_client.php + gif_source.php
docs/         — Internal docs: security audit (AUDIT.md), CenterEdge API reference (CENTEREDGE_API.md + api-reference/ OpenAPI), MSSQL driver setup (MSSQL_DRIVER.md), incident write-ups
```

## Development Notes

### Database
- SQLite with WAL mode, foreign keys enabled, 30s busy timeout
- Parameterized queries use positional `:p0, :p1, ...` placeholders
- Schema auto-initializes on first DB access (CREATE TABLE IF NOT EXISTS)
- Migrations via ALTER TABLE in try/catch for backward compat
- **`DB::each()` — stream a read you are AGGREGATING; `DB::query()` only when
  the caller really needs the rows.** `query()` materializes every row first, at
  ~900 bytes of PHP array per row, and the app runs on the stock `php:8.3-fpm`
  **128M `memory_limit`**. The WEB tier keeps that deliberately — there a
  runaway read is a bug to catch, not to feed — but the two CLI batch units and
  `run.sh` now pass `-d memory_limit=512M` (`deploy/write-daily-unit.sh`),
  because 128M is a web-tier figure and a nightly job that aggregates the whole
  raw feed has no business sitting one busy season away from a fatal. That is
  HEADROOM, never a substitute for streaming. Blowing the limit is a
  FATAL, not an exception: `index.php`'s handler never runs, the response
  carries NO JSON body, and `public/js/api.js` can only report
  **"Request failed (HTTP 500)"** — a bare 500 with no message anywhere in the
  UI is the signature of this bug, not of a caught error.
  **MEASURED Aug 2026:** the Go-Kart Labor page 500'd on Month and Year while
  Day and Week worked, because `laborRideStats()` asked `perfDailyPerGame()`
  for EVERY game to count eight kart readers, and that pulls the raw play feed
  (`game_play_transactions`) into one array. Day/Week overlap only a few days
  of the 28-day raw window; Month/Year overlap all of it. At ~2,600 plays/day
  it peaked at 70-86MB and survived; the threshold is ~4,000 plays/day, and a
  venue summer crossed it. `analyticsGamesLeaderboard`, `analyticsReaderGroupDetail`
  and `analyticsOverview` were the same read away from the same death and are
  fixed too (measured at 12,000 plays/day: 304-338MB → 6-44MB, output
  byte-identical across 30 endpoint/range combinations).
  **THE SAME BUG THEN KILLED THE NIGHTLY CRON FOR A WEEK (Sep 2026), because
  that fix was applied to the WEB endpoints and stopped there.** `cron.php` ran
  on the same 128M limit and both of its aggregations still used `DB::query()`
  over the raw feed: `rollupDailyStats()` (28 days ≈ 300k rows at this venue)
  and `rollupCardActivity()` (the WHOLE table, no date bound). Measured on a
  336k-row feed: the read alone fatals at 128M; streamed, both now peak at
  **62MB**. The venue log is unambiguous — `Allowed memory size of 134217728
  bytes exhausted in lib/scheduler.php` (the rollup's aggregation loop) and
  `in lib/db.php` line 1267 (`DB::query()`'s `$rows[] = $row`).
  Two things made it far worse than a failed step:
  - **The fatal landed BEFORE the purge**, so the raw feed was never trimmed to
    its 30-day window, grew, and made the next night's read bigger — a spiral.
    `rollupCardActivity()`'s comment even said its input was "already bounded to
    ~30 days by the purge", relying on a LATER step in the same script that had
    itself stopped running. **Never assume a sibling step pruned your input.**
  - It is a FATAL, so it took every later step with it — including the venue
    rollup refresh, which is why the reporting numbers froze. That coupling is
    fixed separately (see `cron.php` under **Key Files**), but the memory bug is
    the root cause.
  When you fix a `DB::query()` blow-up, **grep the CRON path too** — it has no
  user watching it fail, and its inputs are the biggest in the app.
  Two rules follow, and the second is the one that actually saves you:
  **stream anything reduced on the spot**, and **filter to the games you
  report on** — `perfDailyPerGame()`/`perfRawDailyPerGame()`/
  `perfRollupDailyPerGame()` take an optional `$onlyGames` set (chunked
  `IN`-lists via `perfGameFilterChunks()`, `idx_gpt_game_time` covers it), the
  same shape `readerHourlyRows()` already used. An empty set means NO games,
  never all of them. A row-count guard is not a substitute: the read that kills
  you is the one whose OUTPUT is small.

### Reporting & Analytics
- **ACTUALS ONLY — no projections, no averaged baselines.** A standing product
  rule for this app: every number a user sees is something that actually
  happened. Do NOT add end-of-day/period projections, run-rate extrapolations,
  "typical day" baselines, or estimated dollars — and prefer real totals over
  averages when a panel has to pick one. Things removed under this rule, so they
  don't get reintroduced: the dashboard's "Today's pace" card and its
  `GET /api/games/transactions/pace` endpoint (projected tickets by close +
  typical-same-weekday baseline), the "Daily pace (7d)" KPI tile (7-day average),
  the Labor page's per-day / per-weekday-occurrence averages, and the Labor
  "rides × price" estimate mode. Averaging is still fine where it IS the metric
  (e.g. avg tickets per play), and the Card Loads bonus-dollar figure is a
  unit conversion of a recorded value-unit amount, not an estimate of activity.
- **Year over year (`GET /api/analytics/yoy`)** — month-to-date and year-to-date
  actuals against the identical stretch of the prior year. Rendered by the shared
  `App.buildYoyCard()` / `App.renderYoy()` widget (in `public/js/app.js`,
  styled by `public/css/components/yoy.css`) on BOTH the Command Center
  dashboard (`#/dashboard`, where the removed pace card used to sit) and the
  Analytics page (`#/analytics`, range-independent — it ignores the top-bar
  period picker and says so by printing its own coverage window). `through` is
  the newest COMPLETE local day the source covers (never today, which is partial
  by definition), and the prior year is cut at the same month/day with Feb 29
  clamped to Feb 28. SINGLE-SOURCE across all four windows so the two sides
  always share a definition: `venue_daily_stats` (the POS ledger rollup, ~2
  decades — money = play value) whenever it has any row, else `game_daily_stats`
  (the app's own rollup — money = cash at readers), reported as `source`
  `ledger`|`app`. `prior_has_data` is false when the prior year has no covered
  days, so the UI says "no 2025 history" instead of a fake +100%. Money is
  scrubbed to 0 for roles without `view_revenue` like every other dollar.
  **Both windows are cut at `through`, not at today, so a source that stops
  advancing renders a perfectly clean card of the wrong month** — this is how
  the venue dashboard sat on "Month to date · Jul 1 – Jul 16" through late
  August 2026 (see the frozen-rollup entry below). Two guards, do not remove
  them: the MTD label names its month outright ("July to date") whenever
  `through`'s month isn't the current one (same for the year), and the payload
  carries `expected_through` (yesterday, venue-local) + `stale_days`.
  **`stale_days` 1 is NORMAL** and must not warn: the nightly refresh runs at
  00:05 UTC = 20:05 the previous day Eastern, so it writes days `< ` a local
  date that hasn't ended yet.
  `days` on each window counts days that CARRY ROWS, not calendar days — a
  YTD reading "Jan 1 – Jul 16 · 185 days" against 197 calendar days means 12
  closed days, not a gap.
  **`stale_days` DOES NOT NAME A CAUSE, and the banner must never make it —
  see `rollup_health` below.** Both rollups store one row per day that HAS
  ACTIVITY, so a day the venue was shut leaves exactly the trace a night the
  refresh never ran does: nothing. Interior holes are safe to read as coverage
  (the rollup demonstrably moved past them), but the NEWEST day is not — four
  quiet days at the end of a season and four dead cron runs both stop
  `MAX(stat_date)` at the same place. The card used to assert one of them
  outright ("the nightly refresh has not advanced them"), which sends somebody
  to debug a working systemd unit; dropping the warning instead would re-open
  the six-week freeze that nothing shouted about. Evidence settles it, not
  inference.
- **`rollup_health` (`Reporting::rollupHealth()` / `classifyRollup()` in
  `lib/reporting.php`) is the thing that decides whether to warn.** Carried on
  the yoy payload AND inside the Analytics deep-history `history` block, and
  read by `check_rollups.php`, so the page, the banner and the CLI can never
  disagree about what the evidence means. It weighs two facts, both local — no
  MSSQL round trip:
  1. **A watermark the refresh writes itself** (`Reporting::markRollupRefreshed`,
     config keys `venue_daily_refresh_*` for the ledger and
     `game_daily_rollup_*` for the app rollup): when it last ran and the newest
     complete day that run covered. Written ONLY after the last batch commits,
     so a run that throws part way still reads as behind. This makes "the job
     ran" a recorded fact instead of a guess about missing rows.
  2. **The app's own raw play feed as an independent witness** of whether the
     venue did business on the days the rollup has nothing for. `cron_watchdog.php`
     polls it every minute on the STOCK image, so it keeps advancing through
     precisely the MSSQL and nightly-cron failures that freeze these rollups.
     One `COUNT(*)`, never a row fetch (the feed runs to thousands of plays a
     day — see the `DB::each()` rule under **Database**), and it reports whether
     it still retains that far back, because an empty count over days the
     ~30-day feed has already purged proves nothing.
     **SILENCE ONLY COUNTS FROM A WITNESS KNOWN TO BE AWAKE** (`feed_live`,
     `Reporting::feedIsLive()`): the `quiet` verdict rests on the feed being
     EMPTY, and a watchdog that stopped polling is exactly as empty as a closed
     venue. So it is trusted only while the watchdog HEARTBEAT is fresh
     (`FEED_WITNESS_MAX_AGE` 900s — the heartbeat is written every minute
     whether or not anyone swiped, which is precisely why the feed's own rows
     cannot stand in for it) and no `game_tx_backlog_*` flag says it is still
     catching up. Otherwise the verdict is `unknown`, never `quiet`. Without
     that guard two dead data paths would report as a reassuring "nothing to
     fix here" — the one direction in which this verdict could be WORSE than
     the false alarm it replaced. Recorded plays still decide it outright: a
     poller that captured activity was plainly running when it mattered.
  Five states: `ok` (within the 3-day tolerance), `stalled` (the refresh itself
  stopped — the actionable fault, and the shape the six-week freeze had), `gap`
  (the refresh covered those days but the source has no rows while the app saw
  plays — business missing from the POS, not from the job), `quiet` (covered,
  and neither source saw anything — the venue was shut; **NOT a warning**, and
  killing that false alarm is the whole point), `unknown` (no watermark yet, or
  the feed no longer reaches back over the gap — warn, but name no cause).
  `warn` drives the styling; `quiet` renders in the neutral `.yoy-quiet` voice
  the coverage line uses. The classifier is PURE so the boundaries are pinned by
  `tests/test_rollup_health.php` (`php tests/test_rollup_health.php`, no DB, no
  network) rather than only ever exercised on a venue at 4am. Wording lives in
  PHP; the client only reformats the dates inside it (`App.humanizeDates`).
  **`/api/health` also reports the watermark** under `rollups.ledger` /
  `rollups.app` (`last_refresh`, `covered_through`, `newest_day`,
  `days_behind`, `healthy`), so a stalled nightly job is machine-visible
  without waiting for somebody to open the dashboard — which is what let the
  last freeze run six weeks. Two properties, both deliberate: it NEVER moves
  the top-level `status` (same rule as the two Slack bots — a reporting table
  falling behind pauses nothing, and that field has to stay trustworthy), and
  it reports the WATERMARK ONLY — two config reads plus an indexed `MAX`, no
  feed scan, because this endpoint is unauthenticated and may be polled hard.
  The closed-vs-broken reasoning stays on the page and in `check_rollups.php`,
  where a human is asking. `healthy: null` means no refresh has ever been
  recorded (not yet upgraded, or a rollup this install doesn't populate) —
  unknown, not sick. `newest_day` is reported BESIDE `covered_through` rather
  than instead of it: that pair IS the distinction this whole entry is about.
- Raw play feed (`game_play_transactions`) is a short rolling window (30 days)
  for the live feed, per-game drill-downs, and hourly reporting.
- `Scheduler::rollupDailyStats()` (run nightly by `cron.php` BEFORE the purge)
  aggregates the raw feed into the permanent per-game, per-day `game_daily_stats`
  table, so month/year performance history survives indefinitely. CenterEdge has
  no reporting API — all aggregation is done locally. History from BEFORE the app
  started is one-time backfilled from the MSSQL `PlayerCardTrans` ledger
  (`Scheduler::backfillGameStatsFromMssql()`, run automatically by `cron.php`,
  flag `game_stats_backfill_done`): plays/value/unique-cards per game/day/hour,
  mapped `rdrkey`→`game_id` via `ReaderDevices`. Tickets/cash/time-plays stay 0
  on backfilled rows (no per-game source — every ticket credit has `rdrkey` 0),
  and only days BEFORE the live rollup's coverage are written, so nothing
  double-counts (expect a small seam at that boundary between the two sources).
- Reporting endpoints (`GET /api/analytics/games`, `GET /api/analytics/game`)
  stitch the rollup (older days) with the raw feed (recent days) at a split
  point safely inside raw retention, so totals are correct AND live. Same
  `analytics` role gate + cash/revenue scrub the Analytics page uses (tech sees
  plays/tickets, never dollars). Powers the Performance page
  (Day/Week/Month/Year/Custom, searchable, with prior-period comparison).
- The same nightly pass also writes `game_hourly_stats` (per-game, per-local-
  hour; ~400-day retention) so hour-of-day history outlives the raw feed.
- **Deep money history (Analytics overview):** the Analytics page's headline
  KPIs + trend reach back ~2 decades even though the raw feed is only ~30 days.
  A venue-wide daily rollup, `venue_daily_stats` (per local day: `plays`,
  `value`, `tickets`, `unique_cards`), is aggregated straight from the POS
  ledger (`PlayerCardTrans`) — plays + play-value (`DollarAmount`) from
  `TransType 1` reader deductions, tickets from all `ValueNo 3` earned.
  **Do NOT filter plays by `rdrkey<>0` here** (the per-game backfill must, to
  attribute a play to a game, but this venue-wide rollup must not): this venue's
  readers stopped populating `rdrkey` after ~2012 (verified — `TransType 1`
  carries `rdrkey<>0` in 2011 but `rdrkey=0` in 2019/2026), so an `rdrkey<>0`
  filter silently drops every play from 2013 on. `TransType 1` alone is the
  reader-swipe signal across all eras (same as Go-Kart Labor). The backfill is
  version-stamped (`Scheduler::VENUE_DAILY_BACKFILL_VERSION` /
  `venue_daily_backfill_done`) so a definition change auto-rebuilds the rollup
  on the next run instead of being blocked by a stale "done" flag. None of these
  depend on the per-game `rdrkey` mapping, so money/tickets/plays are REAL
  historically (unlike the per-game backfill, which can't attribute plays to a
  game once `rdrkey=0`). Written once
  ~2 decades deep (`Scheduler::backfillVenueDailyStatsFromMssql`, monthly MSSQL
  batches, flag `venue_daily_backfill_done`, via `runPendingBackfills`) and
  refreshed for the trailing 40 days
  (`Scheduler::refreshVenueDailyStatsRecent`) — both MSSQL-only (self-skip if
  unconfigured), and neither touches today (today stays live from the raw feed).
  **THE REFRESH RUNS MORE THAN ONCE A DAY, and it must stay that way.** It used
  to be a single nightly step inside `cron.php`'s scheduler-locked section, and
  that is one attempt per day with no retry: a night the plan was skipped (the
  per-minute watchdog held the lock at 00:05 — `acquireLock(0)` is non-blocking
  and the old code `exit(0)`'d right there, before the reporting work), or threw
  in some unrelated step, cost a FULL DAY of every reporting figure, and the
  misses accumulate with nothing to say so. Two changes fixed that, both
  deliberate: `cron.php` moved the refresh + `runPendingBackfills` into
  `cronRefreshReporting()`, called on EVERY firing — a contended lock now skips
  only the plan, and a failed plan sets `$planFailed` and exits at the END
  instead of before the reporting; and `pause-groups-refresh.timer` (written by
  `deploy/write-daily-unit.sh`, every 2h on the pdo_dblib image) runs
  `run_backfills.php`, which is the same lock-free pair. So yesterday's numbers
  appear within a couple of hours of local midnight rather than depending on one
  nightly firing that may not come. That refresh REACHES BACK to the rollup's newest
  stored day when it is further behind than the trailing window, in monthly
  batches, capped by `VENUE_DAILY_CATCHUP_MAX_DAYS` (400, `clamped` in the
  return when it bites — that case wants a version bump instead). Do not
  simplify it back to a fixed trailing window: after any outage longer than the
  window, a trailing-only refresh resumes 40 days before the fix and leaves a
  PERMANENT hole between there and where the rollup stopped, which no later run
  ever repairs and which under-reports every window spanning it, silently,
  because the missing days aren't in the table to be counted.
  **THE ROLLUP FROZE FOR SIX WEEKS ON THE VENUE (Jul 17 → Aug 28 2026) AND
  NOTHING SAID SO — the shape of this trap outlives the specific bug.** The
  one-time backfill is flag-guarded, so after it runs ONCE the refresh is the
  only thing that ever advances this table; and the refresh runs only from
  `cron.php`, in `pause-groups-daily.service`. That unit was pinned to the
  STOCK `php:fpm` image, which has no MSSQL driver — `update.sh` rewrote only
  the FPM unit with the pdo_dblib overlay (`deploy/write-fpm-unit.sh`). So the
  web tier could query MSSQL all day (Labor/Card Loads/Item Watch worked fine,
  which is what made it invisible) while every nightly `new MssqlClient()`
  threw "No MSSQL PDO driver is installed in this PHP runtime" into
  `data/cron.log`. The rollup stayed at 2026-07-16: the day before the deploy
  that ran the v2 backfill. Fixed three ways — `deploy/write-daily-unit.sh`
  now writes the daily unit on the same image as FPM (called by both
  `setup-fcos.sh` and `update.sh`); `run_backfills.php` also runs the trailing
  refresh, so a deploy can never leave the rollup older than the deploy; and
  the year-over-year card reports `stale_days` (above). **The per-minute
  watchdog deliberately stays on the stock image** — it never touches MSSQL and
  it is the safety-critical pause/unpause path. When adding any cron-only MSSQL
  step, check the daily unit's image first, and give the reader of the number a
  way to see that it stopped moving.
  **A SECOND, QUIETER VERSION OF THE SAME LESSON (Sep 2026).** Once the image
  was fixed the rollup did advance — and still read days behind, because the
  freeze was never the only thing wrong with a once-a-day job on the wrong
  clock. Two independent taxes, each worth a day: the unpinned UTC timer (see
  **Scheduling Engine**) and the single unretried nightly attempt (see the
  refresh entry above). Neither is visible from the code that computes the
  numbers, and both look exactly like "the rollup is behind again". When a
  reporting figure lags, check WHEN the job runs and HOW OFTEN it gets to try
  before assuming the job is broken. `GET /api/analytics/overview` activates deep mode
  ONLY when the requested range starts before the raw feed's earliest day
  (`analyticsRawFloorDate`); it is SINGLE-SOURCE (`analyticsVenueDaily`, the
  rollup only — never mixed with the raw feed, so no definitional seam), swaps
  the headline plays/play-value/tickets to the ledger, and NULLs every
  recent-only panel (hour-of-day, top games, category, payment/brand mix, guest
  insights, per-period unique cards) because they can't be rebuilt from a daily
  rollup. `value` = dollars spent at readers (broader than the recent "Reader CC
  payments" walk-up figure), scrubbed by `analyticsScrubMoney` for roles without
  view_revenue like every other dollar. Trend is per-month for Year-style ranges,
  else per-day (cap 370). The frontend (`public/js/analytics.js`) shows a
  "Historical view" banner with the exact coverage window, renders the deep KPIs
  (labeling money "Play value"), and hides the nulled panels with a
  "recent window only" note.
  **THE FALL-THROUGH WHEN THE ROLLUP CANNOT COVER THE RANGE IS THE DANGEROUS
  PATH, and it is why "the Analytics page looks broken on Month/Year".** Deep
  mode is gated on `has_data` (any row in range). When the range starts before
  the raw floor and the rollup has NOTHING for it, the old code left `history`
  null and rendered the ordinary page — headline KPIs, a full daily chart, top
  games, guests — computed from the raw feed ALONE. MEASURED: with the rollup
  unpopulated, "2026" reported 68,200 plays against a true 1,041,120 (a 93%
  under-report), and June 2026 / 2025 reported a confident **ZERO**, every panel
  populated, no warning anywhere. It does not look broken; it looks like the
  venue did no business. `analyticsOverview` now emits a `history` block with
  **`active: false`** + `reason: no_ledger_coverage` in that case — the client
  keeps the normal layout (`isDeep()` already keys off `active`) and adds a
  warning banner saying the figures cover only the recent window. Do NOT
  "simplify" that back to `if ($history !== null)` around the payload override;
  the two conditions are deliberately different (`!== null` stores the block,
  `active` swaps the payload).
  Deep mode also reports **`covered_days` / `expected_days`**
  (`analyticsWindowDays`, future clipped) and **`stale_days` / `expected_through`**
  (`analyticsYoyStaleDays`, the yoy card's own helper). The split between them is
  the point and must not be collapsed: **coverage is NEUTRAL context** — a closed
  day carries no rows either, so a 45-day interior hole (196 of 242 days, −19% on
  the year) is stated but never styled as an alarm — while **staleness is where
  the warning can come from**, because a rollup that stopped advancing is the one
  thing a reader cannot see for themselves. Tolerance is 3 days, same as the yoy
  card, and for the same reason: a healthy rollup is legitimately 1 day behind
  (it never holds today), so 241/242 on a Year view must stay silent or the
  banner cries wolf every day.
  **But staleness alone is not proof of a fault, and this banner used to claim
  it was** ("The nightly job that reads the card system looks stuck"). At the
  TRAILING edge the closed-day argument above applies just as much as it does in
  the interior: the newest day stops moving whether the job died or the season
  did. So the block also carries **`rollup_health`** (see the yoy entry above),
  which weighs the refresh's own watermark and the app's independent play feed
  and returns one verdict; the banner prints `rollup_health.summary` and applies
  `analytics-deep-note--warn` only when `rollup_health.warn` is set. A `quiet`
  verdict — the refresh is current and nobody swiped — joins the coverage
  sentence in the same neutral voice instead of raising an alarm about a venue
  that was simply shut.
- The Analytics overview and both reader-group endpoints accept
  `exclude_time_plays=1` (a UI toggle on those pages). The overview filters
  whole transactions (exact — excluded plays' tickets/points/payments drop
  too); the reader endpoints subtract play COUNTS only, keeping value fields
  whole so the raw/rollup stitch never disagrees with itself. Day-grain
  splits rely on `game_daily_stats.time_plays`, tracked since the
  `time_plays_daily_since` config stamp (older rollup rows can't be split).
- Go-Kart Labor (`#/labor`, `/api/labor/*`, `lib/mssql_client.php`) compares
  go-kart sales vs staff wages by Day/Week/Month/Year/Custom range (same
  window params + semantics as Performance via `perfResolveWindow`; Year
  renders month rows client-side). Sales = the POS's own "Go Kart Readers"
  division dollars (Sales, DivNo 808 — time passes never post money there);
  labor = the DB-computed wage total per day (the proven DATEDIFF
  expression — PayRate × seconds, unclosed punch accrues only when opened
  today — GROUP BY clock-in day). ALL dollar figures come live from these
  two admin-editable range queries (required `:from`/`:to` placeholders,
  single-SELECT guarded via MssqlClient::assertReadOnly; the legacy
  `dates=` param still works — each requested day is fetched alone, so
  year-over-year date lists never scan the span between them). Hour-of-day
  panels: Swipes by the hour (REAL counts from the app's own reader feed,
  readerHourlyRows stitch, coverage-aware) AND "Money in vs wages out, by the
  hour" + a weekday×hour heatmap (Money/Wages/Rate toggle, numbers in cells).
  The hourly money is REAL, not estimated — a genuine hourly source turned up:
  `PlayerCardTrans` TransType 1 / DivNo 808 carries every kart swipe's true
  clock time + dollars (`labor_hourly_sales_range_sql`), and wages-per-hour
  split each punch's PayRate across the wall-clock hours actually worked
  (`labor_punches_range_sql` + `laborPunchWageHours`; unclosed past-day punch =
  zero, today's accrues to now — same conventions as the daily query). Both are
  admin-editable range queries; Test reconciles the hourly ledger total against
  the daily DivNo-808 posting. (An earlier ESTIMATED hourly panel was removed;
  this one replaced it with ledger data.)
  **VERIFIED July 2026 against the live venue DB:**
  - The daily SALES figure is correct — `Sales` DivNo 808 and `ReaderSales`
    InvNo 3074 agree TO THE PENNY for June 2026 ($65,985.08 both). Two
    independent tables, so the headline number is trustworthy.
  - The hourly ledger runs a few points LIGHT of it ($63,103.33, 95.6%) — not
    every DivNo-808 posting carries a card-ledger dollar amount. Normal and
    expected; the panel now reports its own coverage rather than drawing bars
    that quietly don't sum to the total above (`laborReconcile`, statuses
    ok/partial/missing/unknown, tolerance `LABOR_RECONCILE_TOLERANCE` 0.90).
  - The hourly panel goes EMPTY on old ranges and this is why: `PlayerCardTrans.
    DivNo` was 1 for everything in June 2015, and only carries 808 from ~2019
    on (2019: 8,907 plays, 2023: 5,255, 2025: 2,382, 2026: 5,560). The
    reconciliation reports `missing` for such ranges instead of showing an empty
    chart beside a real daily total.
  - Wages check out: `JobCode 3 'Go-Karts'` runs continuously 2006-04-12 →
    2026-07-31 (32,328 punches) and survived the 2015-01-08 job-code
    restructure that folded `Lazer Tag`/`Rock Wall`/`Free Fall`/`Snack Shack`
    into `Rides`/`Activities`/`POS`. Zero unclosed past-day punches out of 2,763
    since 2025, so the count-zero convention has never fired. Overtime is zero
    for this crew (`TimeClock_WorkHours.OTHours_1` = 0 on every kart row,
    rates $15.75-$16.50), so `PayRate` × elapsed is accurate.
  - **BREAKS ARE UNPAID** (operator-confirmed), so paid hours = elapsed −
    `TimeClock_Weekly.BreakHours`, applied by both the daily wages query and
    the hourly split. **Do NOT switch to `WorkHours` to get this** — measured on
    the venue DB, `WorkHours` is only the elapsed time rounded to 2dp and does
    NOT net breaks out (09:13:09→13:44:30 = 4.5225 elapsed, `WorkHours` 4.52,
    `BreakHours` 0.63). `BreakHours` is in HOURS (0.46-0.63 on real rows ≈
    28-38 min meal breaks); it is populated on ~15% of punches (48 of 312 in
    June 2026) and was overstating wages by $351.74 on $23,058.79 (1.53%,
    moving the labor rate 34.94% → 34.41%). The ledger records how MUCH break
    time a punch had but never WHEN, so the hourly split scales each punch by
    its paid fraction — approximate in placement, exact in total, so the hourly
    panel always ties to the daily wage figure.
  - Both wage queries are admin-editable and persist in `api_config`, so the
    pre-fix text is carried forward via `laborUpgradeStored()` — upgraded only
    on a VERBATIM match of the superseded default (`LABOR_LEGACY_*_RANGE_SQL`),
    never touching a hand-customized query. `laborPunchWageHours()` also
    tolerates rows with no `break_hours` column, so a custom punches query
    keeps working unchanged.
  - OPEN: whether any kart labor posts under `JobCode 44 'Rides'` (26,469
    punches, 2015→now, runs alongside Go-Karts). Also unexamined: `BreakCode`
    (1 on every sampled row) — if the venue ever adds a PAID break code, the
    deduction would need to key off it rather than applying to all breaks. **ACTUALS ONLY** — the hourly panel's
  bars and every heatmap cell are the REAL totals for the selected period
  (`hours[].dollars`/`wages`, `heatmap.rows[].cells[].dollars`/`wages`,
  `heatmap.max_dollars`/`max_wages`). They used to be averages — per day for the
  hour rows, per weekday-OCCURRENCE for the heatmap — with matching "avg"
  tooltips; both were removed so the page never shows a typical day. Heatmap
  rows still carry `occurrences` as context (a window with three Saturdays and
  one Sunday says so), and the heatmap's tap-to-inspect line replaced the hover
  tooltip. The old rides × price "estimate mode"
  (`labor_add_ride_value` / `labor_price_per_ride` / `labor_ride_prices`) is
  GONE: sales are always the recorded DivNo-808 dollars. The only ride config
  left is `labor_reader_group_id` — which reader-group area counts as the karts,
  used for swipe COUNTS only (payload key `ride_counts`, formerly
  `ride_valuation`). Test connection runs both live queries
  and prints a fingerprint (server, DB, freshness, category/division dumps)
  for diagnosing data questions. Connection settings live
  encrypted in api_config. Driver detection tries PDO sqlsrv → dblib →
  odbc; the page reports what's installed. View gate: analytics +
  view_revenue (nav key view_revenue); config gate: settings. The
  sandbox/test env has no MSSQL driver — the live connection test happens
  on the venue server via the page's Test connection button.
  **The swipe COUNTS are the one part of this page that is NOT MSSQL** — they
  come from the app's own feed via `laborRideStats()`, and that is where the
  Aug 2026 Month/Year `HTTP 500` lived: it read every game in the building to
  count eight karts. It now passes its member set to `perfDailyPerGame()`. Do
  not drop that argument; see the `DB::each()` entry under **Database**. A bare
  500 with no error text on this page is a PHP fatal (memory), never the MSSQL
  layer — every MSSQL failure here is caught and reported as `{error}` at
  HTTP 200 on the panel itself.
- Card Loads (`#/cardloads`, `/api/cardloads/*`, `api/cardloads.php`) reports
  the money guests ADD to their cards, by Day/Week/Month/Year/Custom (same
  `perfResolveWindow` window model as Performance/Labor), plus a money-loaded-
  by-hour curve and a day-of-week × hour heatmap (per-occurrence averages, for
  staffing). This venue DEFERS card value (`ApplicationInfo.DeferValuePlayerCards
  = 1`), so a load is stored value — NOT a POS sale — and never appears in the
  `Sales` table; it lives only in the card ledger. Source: MSSQL
  `PlayerCardTrans` TransType 3 ("add value"); `DollarAmount` = real dollars
  paid, `TransDateTime` = a TRUE clock time (unlike `Sales.ShiftDate`, which is
  midnight-only — that's why hour-of-day is real here, not estimated). TransType
  1 = plays (deductions at readers, which reconcile to the Sales "Reader Sales"
  category). Paid loads and comped/bonus value (value adds with no DollarAmount,
  estimated from card value-units at ~100/$) are shown SEPARATELY. One
  admin-editable range query (`cardloads_range_sql`, required `:from`/`:to`,
  single-SELECT guarded via `MssqlClient::assertReadOnly`) returns per-(day,
  hour) buckets with paid_*/bonus_* columns; PHP rolls up daily/hourly/
  weekday×hour/summary, so a Year view costs the same one round-trip as a Day.
  Shares the Go-Kart Labor page's MSSQL connection (`lib/mssql_client.php`);
  the connection itself is configured there. View gate: analytics + view_revenue
  (nav key view_revenue); config gate: settings. The Test button reconciles a
  probe day and dumps the day's TransType breakdown. Like Labor, the live query
  only runs on the venue server (the sandbox has no MSSQL driver).
- Ticket Trends (`#/tickets`, `/api/tickets/*`, `api/tickets.php`) reports
  redemption tickets earned by AREA (division) over Day/Week/Month/Year/Custom
  (same `perfResolveWindow` model), with a tickets-by-day trend + a per-division
  breakdown + prior-period delta. Tickets attribute to a `DivNo` (area) but NEVER
  a reader/game — every `PlayerCardTrans` ValueNo-3 (ticket) credit has `rdrkey`
  0 — so the division is the finest grain the POS supports (this is also why the
  per-game backfill leaves `tickets` 0). Source: MSSQL `PlayerCardTrans` ValueNo
  3, `Amount` = ticket-unit count (no dollar value). One admin-editable range
  query (`tickets_range_sql`, required `:from`/`:to`, single-SELECT guarded)
  returns per-(day, DivNo) buckets; PHP rolls up the trend + breakdown. DivNo→
  name is a best-effort INFORMATION_SCHEMA lookup (like Labor). Shares the Labor
  page's MSSQL connection; gold `--tickets` theme. View gate: analytics +
  view_revenue; config gate: settings. Venue server only (no sandbox driver).
- Revenue Mix (`#/revenue`, `/api/revenue/*`, `api/revenue.php`) is the
  P&L-lite roll-up the app was missing: sales dollars by CATEGORY (CatNo /
  area) over Day/Week/Month/Year/Custom (same `perfResolveWindow` model), with
  a revenue-by-day trend + a per-category breakdown (revenue, mix share,
  discount rate, units) + prior-period delta. It frames every other money
  report — attractions vs food vs groups vs card fees, and the mix shift over
  time.
  **The prior-period comparison is CUT TO THE SAME STRETCH when the current
  period is still running** (`revenuePriorWindow`) — the current year is measured
  against last year TO THE SAME DATE, the way the dashboard's year-over-year card
  works, instead of eight months against a full twelve (which read as a collapse
  every August). Year views align on the same month/day via
  `analyticsYoyPriorDate` (Feb 29 → Feb 28); week/month/custom align on ELAPSED
  DAY COUNT, clamped so a 30-day-elapsed March can never spill past a 28-day
  February. A COMPLETED period (any past offset) is untouched — full against
  full, and `prior_aligned` stays false. The summary echoes the exact span
  compared (`prior_from`/`prior_to`/`prior_days`) plus a `compare_label`
  ("vs same stretch last year" / "vs last year" / "vs previous period"), and the
  UI prints both sides ("through Aug 14" on the revenue card, the prior dates on
  the delta card) so the comparison is never left implicit. NOTE the current side
  still includes TODAY, a partial day, exactly as every other page here treats
  the running period — do not "fix" that by silently shifting the headline total
  off the window the user picked. Grain is DAY, not hour: `Sales.ShiftDate` is a business day at midnight
  (no real clock time), so there is no hour-of-day/heatmap here (same honesty as
  Ticket Trends). Source: MSSQL `Sales` — `SUM(AmtSold)` (dollars),
  `SUM(Discounts)`, `SUM(QtySold)` grouped by `CatNo` (all confirmed columns —
  the Labor diagnostics sum them live). Discount rate = discount dollars ÷ gross
  (revenue + discounts), flagged when >10%. One admin-editable range query
  (`revenue_range_sql`, required `:from`/`:to`, single-SELECT guarded via
  `MssqlClient::assertReadOnly`) returns per-(day, CatNo) buckets; PHP rolls up
  the trend + breakdown in `revenueCompose` (pure/testable). Shares the Labor
  page's MSSQL connection; money-green `--revenue` theme. View gate: analytics +
  view_revenue; config gate: settings; Test gate: `data_explorer` (it returns
  raw POS dollars). Venue server only (no sandbox driver).
  **Accuracy properties, all fixed Aug 2026 — do not undo them:**
  - **`share` divides by the POSITIVE revenue pool, not the net total.** A
    category can net NEGATIVE (refunds/voids outrunning sales in the window),
    which drags the net total toward zero while the positive categories keep
    their full value: +$100 and −$80 nets $20, and dividing by that printed
    **"500.0%" and "-400.0%"** on the category table and "500% of revenue" on
    the top-category card. Against the positive pool every positive share is
    ≤100% by construction. When nothing is negative the pool EQUALS the net
    total, so ordinary periods are bit-identical.
  - **The range query reports `truncated`.** `MssqlClient::rows()` stops
    fetching at its limit and returns what it has, with no error — so before
    this, a window over `REVENUE_MAX_ROWS` (40000) silently under-reported
    revenue and looked completely normal. `prior_truncated` covers the
    comparison query. Same contract as Item Watch's `ITEMS_MAX_ROWS`. NOTE
    Ticket Trends and Card Loads still have this gap.
  - **`window.in_progress` — NOT `prev_aligned` — drives the "through <date>"
    note.** `prev_aligned` only means the PRIOR side got trimmed; the two come
    apart whenever an in-progress long month outruns a shorter prior one (Mar 30
    vs a 28-day Feb leaves `aligned` false), which is exactly when the reader
    most needs telling that "March 2026" stops on the 30th. The delta card also
    prints "30d vs 28d" whenever the two sides span different day counts.
  - **`revenueCatNames()` scores candidates instead of taking the first.**
    `LIKE '%Cat%'` is a case-insensitive SUBSTRING match, so `ApplicationInfo`,
    `Allocations` and `Duplicates` all match — and first-match-wins in
    alphabetical order meant any of them (all sort before `Categories`) starved
    the real table and left every category reading "Category 108". Now: a bare
    `No`/`ID` key is only trusted on a table whose NAME looks like a category
    table (`revenueCatTableScore`), candidates are probed in score order, and
    the winner is the one naming the most CatNos ACTUALLY IN THE WINDOW.
    Bounded by `REVENUE_CAT_PROBE_MAX` with early exits, since it runs per
    request. Same false-positive shape as the Explorer's cost probe.
  - **`per_day` still averages over CALENDAR days** — the convention Card Loads
    / Ticket Trends / Redemption share, deliberately left alone — but the
    summary now also carries `days_with_sales`, and the UI prints "N of M days
    with sales" whenever they differ, so a window spanning closed days explains
    its own average instead of just reading low.
  - **The prior-period sum is filtered to the prior window**, symmetric with
    how `revenueCompose` filters the current side, so a customised query
    returning extra days can't inflate one side of the comparison.
  - **The Test button genuinely reconciles**: the saved query's total for the
    probe day against a direct independent `SUM(AmtSold)` over the same day
    (reports MATCH or the exact gap), and it settles the one thing that had
    only ever been ASSUMED — whether `AmtSold` is NET of discounts. A fully
    comped line decides it (net stores AmtSold 0 with the price in
    `Discounts`; gross stores AmtSold == Discounts), counted over 30 days.
    **If that probe ever reports "looks GROSS", the discount rate on this page
    is understated and `discount_pct`'s formula must change.**
- Redemption Economics (`#/redemption`, `/api/redemption/*`, `api/redemption.php`)
  is the redemption half of the ticket economy — Ticket Trends reports tickets
  EARNED, this reports tickets SPENT for prizes, so together they give the
  redemption RATE (redeemed ÷ earned) and the period's net change in outstanding
  ticket liability. Over Day/Week/Month/Year/Custom (same `perfResolveWindow`
  model): a tickets-redeemed-by-day trend, a redemptions-by-hour curve, a
  weekday×hour heatmap (counter staffing), redemption %, period net float, and a
  per-prize mix. Source: MSSQL `RedeemReceipts` — the redemption RecType
  DEPENDS ON THE CARD SYSTEM: the current CenterEdge/Kiosoft readers (live since
  ~end of April 2026) write `RecType = 1`; the legacy Embed system used
  `RecType = 3`. Default filters `RecType = 1 AND TotalTickets > 0`.
  `TotalTickets` = tickets spent, `RecTime` = a TRUE clock time
  (`RedeemDateTime` is sometimes null/anomalous, so `RecTime` drives day +
  hour), plus `RedeemRecItems` (per-prize line items: `InvNo`, `NumberTickets`,
  `Qty`) for the prize breakdown. Prize MARGIN is NOT available — RedeemRecItems
  has no cost column — so the prize panel is a MIX (tickets/qty), not COGS; a
  prize-cost source would be needed for margin. All-time outstanding ticket
  float would come from `EmbedBalance.ETickets` (a candidate table); this report
  shows the PERIOD net (earned − redeemed). Two admin-editable range queries
  (`redemption_range_sql` + `redemption_items_sql`, required `:from`/`:to`,
  single-SELECT guarded); the redemption RATE reuses the Ticket Trends earned
  query (`ticketsRangeSql`) as the denominator. Prize names via best-effort
  INFORMATION_SCHEMA lookup (Inventory/Merch/Prize table). Violet `--redemption`
  theme; heatmap reuses the `cardloads-heat*` classes. View gate: analytics +
  view_revenue; config gate: settings; Test gate: data_explorer. The Test button
  dumps a RecType breakdown + reconciles line-item vs receipt-header ticket
  totals. Venue server only (no sandbox driver).
- Promotional Cards (`#/promotions`, `/api/promotions/*`, `api/promotions.php`)
  tracks BLOCKS of giveaway cards by card-number RANGE (e.g. "K104 on-air
  giveaway, cards 100000–100499, $30 each") and measures how they performed:
  how many came back (activation), reloads + average additional $, plays,
  tickets earned, value spent, and a per-card drill-down. Modeled on Reader
  Groups (a managed list of ranges + click-through detail): batch DEFINITIONS
  live in SQLite (`promo_batches`: name, card_from/card_to, giveaway_date,
  initial_value, notes — no child table, a batch is just a range), while every
  PERFORMANCE number is computed LIVE from MSSQL `PlayerCardTrans` by card
  number. A card never used has NO ledger rows, so "cards used" = distinct
  cards that appear and activation = used ÷ range size (`card_to−card_from+1`).
  Metric defs (important — a giveaway is bulk-loaded up front, so "loaded" ≠
  "used"): `cards_used`/"played" = distinct cards with a `TransType 1` PLAY (came
  back and used); `cards_loaded` = distinct cards with a `TransType 3` (carry the
  promo value); `reloads`/"additional money" = PAID top-ups only (`TransType 3`
  AND `DollarAmount > 0`) — the initial promo value is COMPED (`DollarAmount 0`)
  so it is NOT a reload; `plays`/value = `TransType 1`; `tickets` = `ValueNo 3`.
  The per-card table filters to cards with real activity (played / earned tickets
  / paid reload), so bulk-loaded-but-unplayed cards don't fill it with zeros.
  One admin-editable aggregate query (`promo_range_sql`, a WITH-CTE with
  placeholders `:since`/`:cardfrom`/`:cardto`, single-SELECT guarded). **Card
  numbers get reissued to different physical cards over the years**, so the
  query DEDUPES to the MOST RECENT card per number: per `TRY_CONVERT(BIGINT,
  CardNumber)` it splits activity into "lives" at any gap > 365 days (a reissue)
  and keeps only the latest life — otherwise a decade-old card's plays/tickets
  get folded into a recent giveaway (the bug that made a 51-card range read
  "94 cards, 184%"). `cards_used` counts `DISTINCT cn` (the numeric value, so
  `0288051`==`288051`). The `:since` floor bounds the scan on the `TransDateTime`
  index (a bare `TRY_CONVERT` card-range scan is non-SARGable): the giveaway
  date when set, else a recent default (`PROMO_DEFAULT_LOOKBACK_DAYS`, ~3y) since
  the dedup already drops older reuse. The giveaway date is OPTIONAL (a
  speed/precision knob, not required). Card-range bounds are inlined as validated
  integer literals via `MssqlClient::bindCardRange` (digits-only →
  injection-proof, same rationale as bindDate/bindRange). `TRY_CONVERT(BIGINT,
  CardNumber)` tolerates the `000000`/blank card sentinels. (Window functions
  need SQL Server 2012+.) View gate: `analytics` (money scrubbed for
  roles without view_revenue — techs see activation/plays/tickets, never
  dollars); manage gate: `promotions_manage` (its own catalog key, granted once
  to roles holding `reader_groups_manage`); config gate: `settings`; Test gate:
  `data_explorer` (the Test button probes a card range + dumps a sample of the
  card numbers matched, to confirm the range hit real cards). Pink `--promo`
  theme. Batches can be defined even before MSSQL is configured (stats fill in
  later). Venue server only for the live numbers (no sandbox driver).
- Item Watch (`#/items`, `/api/items/*`, `api/items.php`) is the "how is this
  item / this deal selling?" page: an operator-pinned WATCHLIST of POS inventory
  items rendered as cards (units, dollars, a bar sparkline, and the change vs
  the previous period), a click-through detail view, and a BEST SELLERS
  leaderboard for the same window. Modeled on Promotional Cards — definitions in
  SQLite (`watch_items`: name, `inv_nos`, tag, start/end date, notes), every
  number computed LIVE from MSSQL. Browsable by Day/Week/Month/Year/Custom via
  the shared `perfResolveWindow` model.
  **One entry = a SET of `InvNo` values**, not just one: a deal made of several
  inventory numbers (e.g. a 3-ride kart pass + its variants) becomes ONE card
  whose figures are the union, with a per-InvNo breakdown on the detail view
  showing which member is actually moving. Source: MSSQL `Sales` grouped by
  `InvNo` — `SUM(QtySold)` units, `SUM(AmtSold)` dollars, `SUM(Discounts)`,
  `SUM(CostSold)` (the only cost source in the schema — but see the `Sales`
  entry below: `CostSold` is EMPTY on this install, so in practice the margin
  columns stay hidden here. `has_cost` is computed per response and the margin
  UI hides itself entirely rather than printing a fake 100%; the code path is
  live and correct for a venue that does record cost).
  Grain is DAY, never hour — `Sales.ShiftDate` is a business day stamped at
  midnight, so there is no hour-of-day panel here (same honesty as Revenue Mix /
  Ticket Trends). FOUR admin-editable single-SELECT queries: `items_range_sql`
  (per day + InvNo, placeholders `:from`/`:to`/`:invnos` — drives the cards and
  the trend), `items_totals_sql` (per-InvNo totals for the same placeholders —
  used for the prior-period comparison and the since-launch figures, so a
  multi-year lookback costs one row per item instead of one per item per day),
  `items_top_sql` (the leaderboard, `:from`/`:to`/`:rankexpr`), and
  `items_history_sql` (the multi-period table, `:from`/`:to`/`:invnos`/
  `:periodexpr`). `:invnos` is inlined as a validated comma-separated integer
  list by `MssqlClient::bindIntList` (digits-only → injection-proof, same
  rationale as bindDate/bindRange/bindCardRange); an EMPTY list throws rather
  than producing `IN ()` or an unfiltered scan.
  **`GET /api/items/history`** is the "how is it doing over various periods"
  view, deliberately INDEPENDENT of the page's period picker: the last N
  calendar days/weeks/months/quarters/years for one item, each row with units,
  money and the step change against the row above. Takes `?id=` (a watched
  entry) OR `?inv=7157,7158` (any ad-hoc InvNo), so an item can be examined
  straight off the best-sellers leaderboard without pinning it first — that is
  what the per-row "History" button opens. Grouping happens IN SQL via
  `:periodexpr`, so a 5-year lookback returns ~5 rows, not days × items;
  `ITEMS_PERIOD_EXPR` is a server-side ALLOWLIST (never request input) keyed by
  grain, and the PHP key builder (`itemsPeriodKey`) must produce byte-identical
  keys or the zero-fill silently drops every row — there is a unit test pinning
  the two together. The week expression counts days from a known Sunday
  (1900-01-07) instead of using `DATEPART(WEEKDAY, …)`, which shifts with the
  connection's `SET DATEFIRST`. The newest row is normally a period IN PROGRESS:
  it is flagged, hatched, excluded from the totals/averages/best-period picks,
  and its change renders NEUTRAL with a "so far" suffix — a month that is three
  days old is not "down 70%".
  **Comparison basis** (`?compare=prev|yoy`) switches every change figure
  between the immediately preceding span and the same calendar dates a year
  earlier (via `analyticsYoyPriorDate`, so Feb 29 clamps to Feb 28). For a
  seasonal venue the year-over-year reading is usually the honest one.
  **Leaderboard ranking** (`?rank=revenue|units|margin`) swaps the `ORDER BY`
  through the `ITEMS_RANK_EXPR` allowlist, so the SQL picks its TOP N on the
  measure actually being ranked rather than re-sorting a revenue-shaped pool. A
  stored query customized with its own `ORDER BY` has no `:rankexpr` to swap —
  that is not an error, it reports `rank_locked` and the UI disables the control
  with the reason.
  The watchlist toolbar (search by name/tag/InvNo, tag chips, sort by
  units/revenue/biggest gain/biggest drop/name/recently added) and both CSV
  exports are pure client-side work over the already-loaded payload, so they
  cost no extra query; the CSV mirrors exactly what is filtered and sorted on
  screen, and drops every money column for a money-blind role.
  **ACTUALS ONLY** — every figure is a real total for the selected window. The
  prior-period fields are null (not 0) when the previous period has no rows for
  those items at all, so a newly-added item says "no prior" instead of showing a
  fake −100%. Setting a start date adds a "since it launched" block (clamped to
  ~5 years back, and it says so when clamped) that deliberately ignores the
  period picker.
  Caps, all reported rather than silent: 50 InvNos per entry (validation), 120
  InvNos per page load across the whole watchlist (entries past it are listed
  WITHOUT numbers and the payload carries `stats_skipped`), and 60,000 rows on
  the day-grain query (`truncated` flag → the UI says the totals are incomplete
  and to narrow the period). Item NAMES come from a best-effort
  `Inventory.Description` lookup, falling back to INFORMATION_SCHEMA discovery
  (same approach as the Revenue Mix category lookup); a miss just shows
  "Item 7157". View gate: `analytics` (money scrubbed for roles without
  `view_revenue` — techs see units, unit trends and days-sold, never dollars or
  margin); the best-sellers leaderboard is RANKED by dollars end to end so it
  requires `view_revenue` outright rather than being scrubbed. Manage gate:
  `items_manage` (its own catalog key, granted once to roles holding
  `promotions_manage` by `migration_items_manage_v1`); config gate: `settings`;
  Test gate: `data_explorer` (the Test button dumps the window's top InvNos with
  names and per-item cost — the fastest way to find an item's number — states
  the `CostSold` coverage ratio outright, reconciles the day-grain query against
  the totals query, and runs the history query on ALL FIVE grains checking each
  ties back to those totals. With the InvNo box left blank it probes the range's
  top seller automatically, so the reconcile and grain checks never depend on
  remembering to fill a field — they were skipped on two consecutive venue runs
  before that fallback existed). Teal `--items`
  theme. Items can be pinned before MSSQL is configured (numbers fill in later).
  Venue server only for the live numbers (no sandbox driver).
  **VERIFIED against the live venue August 2026** via that Test button: connected
  through dblib, the day-grain and totals queries agree to the penny (5,034
  units / $179,289.46 on a 30-day window), and item names resolve through
  `Inventory.Description`. The page's numbers are confirmed, not just unit-tested.
- Database Explorer (`#/explorer`, `/api/explorer/*`) is a READ-ONLY window
  into the CenterEdge MSSQL database (shares the Labor page's connection)
  for finding where metrics live: table browser (columns/types, date-column
  freshness MIN→MAX, sample rows), "Find a metric" grouped totals over a
  date range (the generalized DivNo-808 probe), and a free-form guarded
  SELECT with CSV export. Gate: `data_explorer` (admin-only by default — a
  dedicated permission separate from `settings`, so a technician who holds
  `settings` for CenterEdge/timezone config cannot reach raw POS data here; the
  same key also gates the MSSQL report Test buttons on Labor/Card Loads/Ticket
  Trends/Revenue Mix). Builder identifiers are
  validated against INFORMATION_SCHEMA then bracket-quoted; free SQL goes
  through MssqlClient::assertReadOnly; rows are capped (500) and cells
  clamped; aggregate/query runs are audit-logged to action_log. Row counts
  come from sys.partitions when readable (COUNT(*) on a years-deep Sales
  table is never run). SQL errors return structured `{error}` (HTTP 200) —
  they're the expected failure mode while exploring.
- **Per-game history reach probe (`GET /api/explorer/history-sources`,**
  "How far back can per-game history reach?" card on `#/explorer`). Performance
  attributes a play to a game via a READER KEY, so per-game history stops at
  the Embed → CenterEdge/Kiosoft cutover (`EXPLORER_CUTOVER_DATE`, ~May 2026)
  unless some table carries a usable reader key on older rows. The probe
  answers that against the live DB instead of guessing: it scans
  INFORMATION_SCHEMA for every table having BOTH a reader-key-ish column
  (`rdrkey`/`readerkey`/`readerid`/…, see `explorerIsReaderKeyColumn`) AND a
  date column, sizes them via sys.partitions, then for the largest few
  measures key coverage **YEAR BY YEAR** (`explorerProbeReaderYears`, one
  grouped pass per table) and — whenever ANY year has keys — how many resolve
  to a current game through `ReaderDevices` + the same name normalization the
  per-game backfill uses (`explorerNormName` mirrors
  `Scheduler::normReaderName`). Returns a `recommended` source or null, and the
  UI prints a plain verdict either way plus the per-year table behind it. Every
  check is independently try/caught, so one failure never takes the others
  down. Gate: `data_explorer`; audit-logged; venue server only. **Both facts
  matter** — a populated key that no longer maps to a game attributes to
  nothing.
  **Three false-negative bugs this shipped with, all fixed — do not
  reintroduce:** (1) it sampled ONE hardcoded month per era (Feb 2026), but key
  population varies WITHIN an era, so it read zeros and declared no per-game
  history existed while eight fully-attributed years (2005-2012) sat in the
  column it had just sampled; coverage is now measured per year, never assumed
  from the cutover date. (2) the mapping check only ran when that sample month
  had keys, so on this DB it never ran at all — yet the UI still reported the
  full conjunction ("no populated key AND none resolve"), asserting a result it
  had never tested; it now runs against the most recent year that HAS keys.
  (3) the populated-test was `<> 0`, which THROWS on a varchar key (T-SQL tries
  to convert), hiding the Embed `GameStation` columns entirely; the predicate is
  now type-aware (`explorerKeyPopulatedExpr`). Also: the date column is chosen
  by name preference (`explorerPickDateColumn`) rather than first-date-column-
  wins, since a table whose `CreatedDate` precedes its `ShiftDate` would
  otherwise be probed on the wrong column and read as empty.
  **A mapping miss can be a NAMING problem rather than a missing-data one** —
  exact normalized string equality can't match `1lazer tag` to a current "Laser
  Tag". But it can equally mean the machine is simply gone, and a bare "no
  match" cannot tell the two apart, so the probe reports the CLOSEST current
  game name and a 0-100 similarity for every miss (`explorerNearestName`), plus
  the size of the pool it compared against. Measured separation: a punctuation
  or spelling gap scores 89-100 (`1lazer tag`→"Laser Tag" 88.9, `1Go Kart Mini
  Indy`→"Go-Kart Mini Indy" 94.1, `tin can alley #1`→"Tin Can Alley 1" 96.8),
  while a retired machine scores 29-39 (`crane 2 mp3` 38.5, `Yellow Submarine`
  33.3). So the near-miss column decides whether a hand-built crosswalk would
  pay off or whether the floor has simply turned over — do not assume either.
  **MEASURED August 2026, and it was a NAMING problem after all:** the venue run
  came back 3 of 98 with near-misses at 92-93%, and the near-miss column showed
  why — the card system reports game names as CamelCase with NO SPACES
  (`BattingCage1`, `WheelOfFortune`, `GoKartsSpiral1`, `E-ClawCosmic`) while
  `ReaderDevices` descriptions are spaced prose (`1Batting Cage 1`, `Wheel Of
  Fortune`). Collapsing whitespace was never going to bridge that. Both
  normalizers now fold away EVERY non-alphanumeric character, which turns those
  92-93% near-misses into exact matches (`1Batting Cage 1` → `battingcage1` =
  `BattingCage1`) while leaving genuinely different machines apart
  (`1Go Kart Mini Indy` vs `GoKartKiosk` stays a miss). The two copies —
  `Scheduler::normReaderName` and `explorerNormName` — MUST stay byte-identical
  or the probe reports a mapping the backfill would not actually make; a unit
  test asserts they agree.
  Still expect a large residue of genuine misses: `crane 2 mp3`, `Yellow
  Submarine`, `tin can alley #1` score 39-50% against the current floor because
  those machines are gone, and no normalization brings them back.
- **Per-item cost / price probe (`GET /api/explorer/cost-sources`,** "Is there a
  per-item unit cost or list price?" card on `#/explorer`). `Sales.CostSold` is
  the schema's only cost-of-goods column and it is EMPTY here, so gross margin
  needs a unit cost from somewhere else — this answers whether one exists rather
  than guessing. Scans INFORMATION_SCHEMA for every table carrying BOTH an
  inventory-key column (`explorerIsInvKeyColumn` — a bare `No`/`ID` only counts
  on an inventory-ish table, or half the database matches) AND a money-ish
  column classified as cost or price (`explorerCostColumnKind`). Reports cost
  and price SEPARATELY, since they answer different questions (margin vs
  list-vs-actual).
  **The decisive measure is coverage of items that actually SELL, not overall
  population** — a cost populated on 6,000 discontinued SKUs and none of this
  month's sellers buys no margin at all, and would read as a healthy 75% on a
  whole-table count. The probe pulls the recent top sellers from `Sales`
  (`EXPLORER_COST_SELLER_SAMPLE`/`_DAYS`) and reports both figures side by side
  so the gap between them is visible. Verdicts are per-kind and honest either
  way: "usable" at ≥80% seller coverage, "partial" below it (with the note that
  uncovered items must show as unknown, never as 100% margin), "none found"
  when nothing is populated for any seller. With no seller list readable it
  says so instead of printing 0% — which would read as "no cost data exists".
  Lookalike columns are excluded BY NAME (`PriceLevel`, `PriceGroup`,
  `CostCenter`, `PriceCode`…): they are integers that look monetary, and type
  alone can't separate them since some installs store money in int cents — so
  int types are deliberately still accepted.
  **BOUNDED, because the first version timed out on the venue.** Every column
  probe is a full aggregate pass, and the candidate set includes `Sales` and
  `ReaderSales` — both carry an `InvNo` and are ~21M rows here, so scanning
  them (times several columns) blew the request budget. Three limits now apply,
  all reported rather than silent: tables over `EXPLORER_COST_SCAN_MAX_ROWS`
  (750k) are listed with "too large to scan" and never touched (a per-item unit
  cost lives on a MASTER table, so this loses nothing); a wall-clock
  `EXPLORER_COST_TIME_BUDGET` (30s) stops the sweep and marks the rest "time
  budget reached"; and the deadline is checked before EVERY query inside a
  column probe, not just between columns, so worst-case overshoot is one
  12s driver timeout rather than three.
  **Three further defects the first venue run exposed, all fixed — do not
  reintroduce:** (1) an inventory key was matched BY NAME only, so
  `PaymentPlanInventory.InvID` (a `uniqueidentifier`) was joined against integer
  InvNos and threw `Operand type clash`; the key column must now also pass
  `explorerIsInvKeyType`. (2) the size guard read `rows !== null && rows > max`,
  so a VIEW — which has no `sys.partitions` row and therefore null size — slipped
  through: `SalesForAllInventory` (a view over `Sales`) was full-scanned, timed
  out, and **killed the connection**. Unknown size is now treated as unscannable.
  (3) after that timeout, dblib answered `DBPROCESS is dead or not enabled` to
  every subsequent query, so the sweep emitted a dozen identical failures and
  STILL printed "No usable unit cost found" — a verdict from a run that had
  stopped testing anything. `explorerIsFatalDbError` now halts the sweep on a
  connection-fatal error, and the payload carries `connection_lost` plus an
  `unfinished` count so the UI downgrades "none found" to "not finished" rather
  than asserting a negative it never established.
  **A fourth defect, found on the second run and the most misleading of them:**
  seller coverage counted `COUNT(*)` — rows, not items. On a master table those
  are the same; on the 135k-row `GroupLineItems` it reported "25,949 of 120
  recent sellers (21,624%)" and, being the largest number, OUTRANKED the correct
  `Inventory.Price1` answer. Coverage is now `COUNT(DISTINCT key)`, which is
  mathematically bounded by the seller list, and each column also reports
  ROWS PER ITEM so a transaction log is visibly not master data. Ranking
  prefers a master-like source (≤2 rows per item) over a transactional one even
  when the latter shows higher coverage.
  Two smaller ones from the same run: empty tables (`0 / 0`) consumed four of
  the eight probe slots and are now skipped outright, and tables over the scan
  cap are no longer skipped ENTIRELY — the whole-table pass is dropped but the
  bounded `IN (:invnos)` seller lookup still runs, which is the measure the
  verdict rests on. That is what finally tested `InvSnapShot.AvgCost` and the
  `Sales`/`TimeSales`/`CashierSales` cost columns. When the budget bites, the UI says the
  sweep was incomplete so a "none found" verdict is not mistaken for a definite
  answer. Gate: `data_explorer`; audit-logged; venue server only.
- Reader Groups (`reader_groups`/`reader_group_games`, CRUD at
  `/api/reader-groups`, page at `#/readers`) are analytics-only groupings of
  games/readers — they never pause anything, and a game may be in many groups.
  `GET /api/analytics/reader-groups` compares every area (totals, avg plays
  per day / per game per day, busiest weekday+hour, prior-period deltas);
  `GET /api/analytics/reader-group?id=` adds the day-of-week × hour heatmap
  (per-occurrence averages for staffing), trend series, and per-game breakdown.
  Hour-grain data stitches `game_hourly_stats` + raw feed and reports its
  actual coverage window (hourly history only accumulates from feature ship).
  View gate `analytics`; create/edit/delete gate `reader_groups_manage`
  (its own catalog key — a one-time migration granted it to roles that held
  `groups_manage` when the key split).

### CenterEdge MSSQL Database (schema reference)
Everything the reporting features read lives in the venue's CenterEdge POS
database (MSSQL, `[CenterEdge].[dbo].*`), accessed READ-ONLY through
`lib/mssql_client.php` (single-SELECT guarded, admin-editable `:from`/`:to`
range queries). CenterEdge exposes NO reporting API, so all aggregation is
local. The live queries run ONLY on the venue server (the sandbox has no MSSQL
driver). This section records what we've verified about the schema so future
work doesn't re-discover it. **CONFIRMED** = referenced by shipped code and/or
reconciled on the venue via the page Test buttons / Database Explorer.
**CANDIDATE** = seen only in a schema browse (row counts approximate, columns
NOT yet verified live) — treat as a starting point, confirm with the Explorer
before building.

- **Deferred-value model (CONFIRMED, architectural):** `ApplicationInfo.
  DeferValuePlayerCards = 1`. Card value is STORED VALUE, not a POS sale — a
  card load is booked to the card ledger as a liability, NOT to the `Sales`
  table. This is why Card Loads reads the ledger (not Sales), and why per-game
  "cash" is 0 on reader rows in Performance (deferred plays don't post cash to
  `Sales`).
- **`PlayerCardTrans` — the card ledger (CONFIRMED), the single most-used
  source.** One row per card transaction; `TransDateTime` is a TRUE venue-local
  clock time (so hour-of-day is REAL for anything sourced here). Discriminators:
  - `TransType = 1` — plays / deductions at a reader. Carries `rdrkey` (the
    reader) and `DollarAmount` (value spent). Powers the Go-Kart hourly money
    panel and the per-game play-history backfill. `rdrkey` maps to a game via
    `ReaderDevices` (name join — see `Scheduler::backfillGameStatsFromMssql`).
  - `TransType = 3` — "add value" (a card LOAD). `DollarAmount` = real dollars
    paid; value adds with no `DollarAmount` are comped/bonus value (estimated
    from card value-units at ~100/$). Source for Card Loads.
  - `ValueNo = 3` — redemption tickets EARNED. `Amount` = ticket-unit count (no
    dollar value). Attributes to a `DivNo` (area) but **NEVER a reader/game —
    every ValueNo-3 credit has `rdrkey` 0** (confirmed by Explorer; this is why
    Ticket Trends is by-division and the per-game backfill leaves `tickets` 0).
  - Also present: `CardNumber`, `EmpNo` (cashier/employee), `DivNo`. MIN/MAX
    `TransDateTime` per card seeds the guest "new vs returning" ledger
    (`Scheduler::backfillCardActivityFromMssql`), reaching back ~2 decades.
  - **Venue-wide daily rollup (CONFIRMED consumer):** grouped by
    `CONVERT(VARCHAR(10),TransDateTime,120)` (local day), this same table feeds
    `venue_daily_stats` — plays + play-value (`DollarAmount`) from `TransType 1`
    (NO `rdrkey` filter — see below), tickets from all `ValueNo 3`, distinct
    cards — for the Analytics overview's deep money history
    (`Scheduler::backfillVenueDailyStatsFromMssql` / `refreshVenueDailyStatsRecent`).
    Venue-wide (no `rdrkey`→game mapping), so money/tickets/plays are real here
    where the per-game backfill can only leave them 0 once `rdrkey=0`.
  - **`rdrkey` dies after 2012 (CONFIRMED per-year, era gotcha):** measured
    year by year over `TransType 1` on the venue DB — **2005-2011: 100%**
    populated (18 readers in 2005 growing to 97 by 2011); **2012: 76%**
    (760,744 of 997,431 — the transition year); **2013 onward: exactly 0**,
    every year through 2026. So per-game attribution via this column covers
    **2005-2012, ~4.94M plays across 98 readers**, and nothing after. A
    venue-wide count MUST use `TransType 1` alone. Real per-play
    `DollarAmount` is 0 in the early era and populated from ~2013 on — so the
    attributable era and the money-bearing era barely overlap.
    NOTE the shape of this: coverage is NOT uniform within an era, which is
    why sampling one month is not a valid test (see the reach probe below).
- **`Sales` — POS sales lines (CONFIRMED).** `ShiftDate` is a business DAY
  stamped at MIDNIGHT (not a clock time), so Sales-sourced reports are honest at
  day grain only — no real hour-of-day (that's why Revenue Mix / the go-kart
  cash figure have no heatmap). Columns in use: `AmtSold` (dollars), `QtySold`,
  `Discounts`, `CostSold`, `NumberTickets`, `CatNo` (category/area),
  `SubCatNo`, `DivNo`, **`InvNo`** (the inventory item — CONFIRMED: the venue
  already tracks a kart deal in Grafana with `SELECT SUM(QtySold) FROM Sales
  WHERE InvNo = 7157`, and the Item Watch page groups this table by it).
  `CostSold` is the ONLY cost-of-goods column anywhere in this schema — but
  **on THIS install it is empty. MEASURED August 2026 via the Item Watch Test
  button: 0 of the 150 items sold in a 30-day window record any cost**, across
  reader aggregates, admissions, merchandise and F&B alike. So **per-item gross
  margin is NOT available at this venue** and no report should promise it. Item
  Watch already handles this correctly — `has_cost` comes back false and the
  margin columns hide themselves rather than printing a fake 100% — and its
  Test button now reports the coverage ratio outright. Do not re-derive this;
  re-run that button if you suspect the POS config changed. If margin is ever
  wanted, a NEW source is needed, not a different read of `Sales` — run the
  Database Explorer's **cost/price probe** (`GET /api/explorer/cost-sources`,
  below) to find out whether one exists on this install.
  **MEASURED August 2026 by that probe: `Inventory.Price1` IS a usable per-item
  LIST PRICE** — 102 of the 120 recent top sellers (85%) carry a value, range
  $0.01-$3,000, joined on `InvNo`, one row per item. `Price2`/`Price3`/`Price4`
  are 0% populated. So list-vs-actual and discount-depth analysis IS available
  even though margin is not.
  **The cost question IS now closed — there is no per-item unit cost on this
  install.** The second run tested every remaining candidate and none covers a
  single current seller: `InvReceiptItems.Cost`/`StandardCost` are 100%
  populated but across only 162 receipt lines, none of them recent sellers;
  `InvAuditItems.AdjCost`/`OriginalAvgCost` sit at 7% of 717 rows, also zero
  sellers; `InvSnapShot.AvgCost` (6.9M rows) covers zero; `InvReductionItems`
  is empty. Purchase costs exist in the abstract and attach to nothing being
  sold, so margin cannot be computed for the items anyone actually cares about.
  Do not re-open this without new evidence.
  **`GroupLineItems.Price`/`OrigPrice`/`NewPrice` are NOT a master price** — 89%
  populated across 135k rows, but ~220 rows per item, because it is a
  party/booking line-item log. It records what was charged on one booking, not
  the item's price. The probe reports rows-per-item precisely so a transaction
  table cannot masquerade as master data (it briefly did — see below). Confirmed codes on this install: **`CatNo 108` = Go
  Karts** (rides post at `AmtSold` 0 — paid at the reader; walk-up cash posts as
  cash), **`CatNo 106` = Beverages**, **`DivNo 808` = "Go Kart Readers"** (the
  aggregated daily dollars spent at the kart readers — the go-kart sales figure
  on the Labor page). Category/division NAMES are discovered live via
  `INFORMATION_SCHEMA` (a `%Cat%`/`%Div%` table with an int No column + a text
  Name column), because the lookup table's name varies by install.
- **`ReaderDevices` (CONFIRMED):** maps `rdrkey` → reader/game by name. The join
  used to attribute `PlayerCardTrans` TransType-1 plays and the reader feed to
  games (`normReaderName` in the scheduler backfill).
- **Ticket attribution gotcha (CONFIRMED):** in the card ledger, tickets exist
  ONLY at the division grain — every `ValueNo 3` credit has `rdrkey` 0. This is
  why Ticket Trends is by-area and why the per-game backfill leaves `tickets` 0.
  `ReaderTickets` (`rdrKey`, `ShiftDate`, `TicketsDispensed`, `TicketsOnCard`)
  looked like a counterexample but **is EMPTY — the per-year sweep returns zero
  rows.** The table exists in the schema and was never populated. One possible
  early-era exception remains, see `ReaderTransSummary` below.
- **PER-MACHINE IDENTITY DIES AT THE END OF 2012 (CONFIRMED, four independent
  sources).** This is the single most important fact about per-game history on
  this install, and it is now corroborated rather than inferred. Measured per
  year:
  | Source | Key populated | Then |
  |---|---|---|
  | `PlayerCardTrans.rdrkey` | 2005-2011 100%, 2012 76% | 0 from 2013 |
  | `ReaderTransSummary.rdrKey` | 2005-2012 (~90%+) | 0 from 2013 |
  | `CardActivity.rdrkey` | 2005-2012 (~54-78%) | 0 from 2013 |
  | `ReaderSwipes.rdrKey` | 2007-2012 100% | table ENDS after 2012 |
  Four tables, written by different subsystems, all stop recording machine
  identity at the same boundary — so this is a venue-wide configuration change
  in 2012, not a gap in any one table. **Per-game history for 2013 onward is
  not recoverable via reader key from any of these.** Do not re-litigate this
  without new evidence; do NOT read it as "the right table hasn't been found".
  **The search is now EXHAUSTIVE, not pattern-based** — a full catalog sweep
  (`sys.tables` + `sys.columns`, every table over 50k rows with its complete
  column list, 67 tables) found exactly FIVE reader/device columns in the whole
  database: the four above plus `ReaderSales.rdrKey` (also 0 after 2012). No
  other table carries one. `StationNo` (on `Receipt`, `Till`, `AuditLog`,
  `CashierSales`) is a POS register, not a machine. Two further columns on the
  play rows themselves were tested and are NOT identity: `rdrSeq` is 0 in every
  year sampled, and `UseSeq` is a per-CARD use counter (consecutive per
  CardNumber — 1,378 distinct values in 2013, nothing like a machine count).
  **The Kiosoft/CenterEdge cutover does NOT restore it**: June 2026 has 70,840
  `TransType 1` plays and ZERO with `rdrkey`, so MSSQL will never be a per-game
  source going forward either — the app's own API feed (`game_daily_stats`) is,
  and it accumulates from install date. `ReaderDevices` still lists all ~110
  machines individually (`Ms. Pac-Man`, `Ice Ball 1`-`4`, `crane 1 bling`,
  `1Batting Cage 1`-`6`, each with `rdrClass`, `Retired`, `DeviceId` GUID), so
  the machines were never anonymous — they simply stopped stamping identity onto
  transactions in 2012.
  **Per-ATTRACTION history for 2013-2026 DOES exist — see `ReaderSales.InvNo`
  below.** That is the answer to "which games", at attraction grain.
- **`ReaderSales` — the per-ATTRACTION source for 2013-2026 (CONFIRMED).**
  ~20.9M rows; `DataKey`, `ShiftDate`, `rdrKey`, `DivNo`, `SaleAmount`,
  `TaxAmount`, **`InvNo`**. `rdrKey` is dead here like everywhere else, but
  **`InvNo` (the inventory item = the attraction sold at the reader) is
  populated on 100% of rows in every year sampled** (427,060/427,060 in 2013;
  same through 2025), 15-20 distinct items, with real dollars. This is how
  per-attraction history survives the 2012 machine-identity loss — the identity
  moved from a reader column to a product column in a different table.
  - **`ShiftDate` carries the HOUR here** (`2019-06-01 08:00:00`,
    `09:00:00`, …) — do NOT assume it behaves like `Sales.ShiftDate`, which is
    a midnight-stamped business day. Hour-of-day is real for 2013-2026.
  - **`DivNo` is populated** (801, 803, 808, 811 alongside 1) — unlike
    `PlayerCardTrans`, whose `DivNo` collapsed to 1 for everything in the
    mid-2010s (June 2015: all 112,750 plays on DivNo 1).
  - Names via `Inventory.Description`. Measured 2025: `Redemption Game Readers`
    469,211 plays/$777,578; `Merchandise` 103,657/$156,903; `Video Game`
    83,306/$260,343; `Go Kart` 54,576/$458,591; `Driving Range` 28,278/$369,613;
    `Laser Tag` 24,160/$176,967; plus Novelty, Free Fall, Batting Cage, Family
    Swing, Dragon Coaster, Air Hockey, Zipline, Rockwall, Ballocity, Mini Golf.
    ~938K plays / ~$2.79M for the year.
  - Grain is attraction CATEGORY, not machine — "Redemption Game Readers" is
    every redemption cabinet in one bucket. Individual games are not separable.
  - 2013 looks anomalous (3x the rows of other years, $152 total) — `SaleAmount`
    was likely not populated yet, same pattern as early-era `DollarAmount`.
    Confirm the money start year before promising a date range.
- **`ReaderTransSummary` — the best 2005-2012 per-game source (CONFIRMED).**
  `ShiftDate`, `rdrKey`, `ValueNo`, `Quantity`, `TotalAmount`, `Dollars`;
  pre-aggregated per (day, reader, ValueNo). Better than `PlayerCardTrans` for a
  per-game backfill of that era on every axis: it is ~25x smaller (~196K rows
  total for 2005-2012, vs ~5M plays), it is already in the shape
  `game_daily_stats` wants, and **it carries `Dollars` where the early-era
  `PlayerCardTrans.DollarAmount` is 0** ($891K in 2006 rising to $3.87M in
  2011) — so per-game MONEY is available for 2006-2012 even though the raw
  ledger has none. `ValueNo` semantics here: **1** = plays/value (22.19M qty,
  $88.09M, 2005-2026), **2** = 2.33M qty / $27.6K, **3** = tickets (951,642 qty,
  $0 — matching the ledger's ValueNo-3-is-tickets convention).
  CAUTION on ValueNo 3: only 4,124 rows across two decades, which is sparse for
  a ticket arcade — per-game tickets for the early era are PLAUSIBLE but the
  density has not been verified. Measure ValueNo-3-with-`rdrKey` per year before
  relying on it. `Dollars` in 2005 is 0; money starts 2006.
  `StationNo` is NOT a machine identifier — it is a POS register (it appears on
  `Till`, `TaxDocuments`, `RedeemScreens`, `PosKeys`…). Do not treat it as one.

- **CARD-SYSTEM CUTOVER (important):** the venue switched from the **Embed**
  card system to **CenterEdge/Kiosoft** readers ~end of April 2026. Table
  CONVENTIONS can differ across that boundary — e.g. `RedeemReceipts` uses
  `RecType = 1` for redemptions on the new system but `RecType = 3` on legacy
  Embed data (this bit the Redemption report — it shipped filtering RecType 3
  and read zeros until the default was corrected to RecType 1). Any table with
  "Embed" in its name, or any pre-May-2026 assumption, must be re-confirmed
  against recent rows before use.
- **CANDIDATE tables — high-value sources for reports not yet built** (row
  counts from a one-time schema browse; confirm columns via the Explorer first):
  - `EmbedBalance` (~563K) — stored-value balances per card (`Card_Barcode`,
    `Cash_Balance`, `Bonus_Balance`, `ETickets`). Aged by last-activity →
    outstanding liability + breakage. (Snapshot, not a range.) NOTE the
    "Embed" name + cutover above — confirm it still populates post-April before
    building on it.
  - `CreditCardTrans` (~1.2M, `TransDateTime` real clock, `Amount`,
    `ShortAcctNumber`, `CardType`) — real card-tender dollars + brand mix.
  - `GroupSales` (~105K) / `GroupBirthdays` (~24K) / `GroupArrivals` (~32K) —
    parties/birthdays revenue + forward booking pipeline.
  - `Customers` (~131K) / `CustPasses` (~70K) / `CustVisits` (~173K) /
    `CustSales` (~545K) — the durable NAMED-customer dimension (membership /
    season-pass / RFM) the card-number Guest Insights can't reach.
  - `CashierSales` (~3.2M) / `PlayerCardTrans.EmpNo` — per-employee productivity.
  - `TimeSales` (~6.6M, carries `InvNo` AND `HourNo` — real hour-of-day for
    timed attractions); `SubCatSales` (~1.4M) F&B sub-category drill-down;
    `TicketTrans` (~17K) printed vouchers.

### API Pattern
- API handlers are loaded via `require_once` from `index.php` which pre-loads `db.php`, `auth.php`, `csrf.php`, `crypto.php`
- Each handler is a function `handleX($method, $parts, $input)` dispatched from `index.php`
- `$parts` = URL segments after the resource name
- `$input` = parsed JSON body for POST/PUT/PATCH
- RuntimeException → 422, other Exception → 500

### Frontend Pattern
- Routes registered via `App.registerRoute('#/path', { render: fn })`
- API calls via `API.get()`, `API.post()`, `API.put()`, `API.patch()`, `API.del()`
- Note: DELETE method uses `API.del()` (not `API.delete()` — `delete` is a JS reserved word)
- DOM built with `App.el(tag, props, children)` helper

### Staff Birthdays
- **The bot** lives in `birthdays/` and runs from a systemd timer, NOT from the
  app: `birthday_bot.php` reads the employee roster out of the CenterEdge MSSQL
  database and posts a greeting to Slack for anyone whose birthday is today and
  whose `EmpStatus` still says they work here. Read-only against the POS (the
  same single-SELECT guard the reports use) and it never writes back.
  `install.sh` is a one-command installer; `run.sh` wraps the podman/pdo_dblib
  invocation every CLI command needs; `discover.php` re-derives the roster
  query. 310 assertions in `birthdays/tests/` run with no database or network.
- **Roster facts (verified August 2026):** the staff table is `dbo.Employees`
  (NOT `TimeClock_Employees`, which does not exist here), the birthday column is
  `DateOfBirth`, and `EmpStatus = 1` means employed — `dbo.EmployeeStatus`
  spells the codes out (1 Active, 2 Suspended, 3 Terminated). Every OTHER
  birthday column in the schema is the guest side (`Customers`,
  `ChildCustomers`, `GroupChildren`, the waiver tables, `TicketDetails`).
  `dbo.Employees` also carries `SSN`, `PasswordHash`, `PinHash` and
  `FingerprintTemplate` — the bot selects four columns and nothing else, and
  nothing here should ever `SELECT *` from it.
- **The page** (`#/birthdays`, `api/birthdays.php`, `public/js/birthdays.js`)
  shows upcoming birthdays and today's message, and edits every setting.
  Settings resolve through `lib/birthday_config.php` in three layers — built-in
  defaults, then `data/birthday_config.php` if it exists, then `api_config` rows
  keyed `birthday_*`. So a file-only install keeps working and the page's saved
  values win, and the page never has to generate PHP. **`DB::getConfig` already
  decrypts** — do not decrypt a `birthday_*` secret a second time, which throws
  and reads a good token back as "not set". A secret that genuinely can't be
  decrypted degrades to a warning rather than a fatal, so `--check` still runs.
- **`bdayMessageConfig()` (`birthdays/lib/birthday_lib.php`) is the ONE place
  that lists which settings shape a message.** The daily run, `--demo` and the
  page's preview all build their `$msgCfg` through it. They each assembled that
  subset by hand until Aug 2026, and the daily run's copy omitted the four pool
  keys — so a custom greeting saved on the page was shown by the preview, shown
  by `--demo`, and then NOT used by the post that went out. Add a wording
  setting there, never at a call site. Absence is meaningful: a pool key is
  passed on only when it is really an array, because `bdayPickTemplate()` reads
  an absent key as "use the built-in pool" and an empty one as "no flavour line
  at all" — the stored default is null and must land on the first reading.
- **`enabled` ("Post birthday greetings") is honoured by the CLI**, checked
  before the roster read so a switched-off bot needs neither MSSQL nor Slack.
  It shipped as a page field the runner never read, so turning it off changed
  nothing. `--list`/`--dry-run` still report while it is off (that is the point
  of switching it back on), and `--check` prints its own row and will not say
  "everything checks out" while nothing can post.
- **Messages are COMPOSED**, not picked from whole templates: a greeting line
  and a flavour line are drawn from separate pools with independent seeds, so 65
  written lines make 714 messages. Every flavour line must stand alone after any
  greeting (a test enforces capitalisation + terminal punctuation). The pick is
  deterministic from date + celebrants, which is what makes `--dry-run` show
  exactly what will post. **No age, no birth year, no milestones** — about a
  fifth of this roster are minors; a test asserts no pool line contains a
  year-like number.
- **A `--date` other than today is a REHEARSAL:** it always posts and is
  deliberately NOT recorded. Recording it would mark the real morning "already
  done" and silently skip that person's actual greeting.
- **The bot must never fail QUIETLY**, because every failure mode looks like a
  day with no birthdays. Four mechanisms, added Aug 2026 — do not weaken them:
  - **A run record.** Every real firing writes `data/.heartbeat_birthdays` (the
    same convention as `Scheduler::writeHeartbeat`) AND a `last_run` block in
    the state file (`at`/`date`/`outcome`/`count`/`detail`, outcome =
    posted|idle|disabled|failed). `bdayRunHealth()` turns the pair into one
    verdict, shared by the CLI `--check` and the page's check list so they can
    never disagree. Precedence: a `last_run` dated TODAY wins outright (the run
    writes it itself, so it survives a failed heartbeat write); otherwise the
    heartbeat's AGE decides (26h warn, 50h fail). `/api/health` reports the
    heartbeat beside cron's under `birthdays`, but it NEVER moves the
    top-level `status`: that field means "is the pause-group system working"
    (the Electron remote surfaces it), and an optional accessory that pauses
    nothing must not be able to report the scheduler as degraded. A MISSING
    heartbeat is not unhealthy either — the bot is optional and usually just
    isn't installed. A dry run, a `--list`
    and a rehearsal record NOTHING (`$willRecord`); a catch-up firing that
    finds the job already done moves the heartbeat but keeps the earlier
    `posted` outcome.
  - **Retries.** The timer fires three times a day (`install.sh` derives the
    catch-ups from the chosen time, dropping any that would spill past
    midnight); the state file makes repeats no-ops. `SlackClient` also retries
    each call 3× with backoff, honouring `Retry-After`. `SlackClient::isRetryable()`
    is the pure classifier: rate limits/5xx/connection failures yes, a revoked
    token or a channel it isn't in no. A read timeout after the request was
    sent IS retried — the duplicate risk is accepted deliberately, because a
    rare double post beats a silent miss.
  - **A run lock** (`bdayLockAcquire`, `data/birthday.lock`, non-blocking)
    covers the whole posting path. `null` (unopenable) is deliberately NOT the
    same as `false` (someone else holds it): a broken lock file must not cost
    a birthday, so the run continues unlocked.
  - **The timer's TIMEZONE is not the app's.** systemd fires `OnCalendar` on
    the SYSTEM zone; the bot resolves its own (`--print-timezone`, the birthday
    `timezone` setting else `DEFAULT_TIMEZONE`). MEASURED at the venue Aug 2026:
    host UTC, app America/New_York, so a 09:00 timer had been posting at 05:00
    local. `install.sh` now compares the two and emits
    `OnCalendar=… America/New_York` when they differ AND systemd is 252+ (older
    systemd cannot parse a zone in a calendar spec — emitting it there yields a
    unit that never fires, so it warns and prompts instead). Never "fix" this by
    converting to a fixed UTC offset: it breaks at every DST changeover.
    `--check` prints a Clock row so the gap is visible beside
    `systemctl list-timers`.
  - **Audit rows.** Source `birthdays`, actions `birthday_posted` /
    `birthday_failed` — only real events, never the ~300 idle days a year.
    Keep both `api/logs.php` filter allowlists and the `public/js/logs.js`
    dropdowns in sync.
- **`GET /api/birthdays/today`** feeds the Command Center strip (see the
  Work Anniversaries section for the whole design — the strip carries both
  bots). NAMES ONLY in that payload: no age, no birth year, not even a field
  for one, for exactly the reason the greeting is forbidden from carrying
  either. Memoised through the shared `lib/today_cache.php`, keyed by
  `bdayTodaySignature()`.
- Gates: `view_birthdays` (page, in `PAGE_PERMISSIONS`) and `birthdays_manage`
  (edit settings, post test messages). `migration_birthdays_v1` grants both to
  roles holding `settings`. Keep the key in sync across `Auth::PAGE_PERMISSIONS`,
  settings.js `pagePermissionKeys`, and app.js `PERMISSION_AREAS` /
  `SECTION_AREAS` / `LEGACY_ACCESS`.

### Staff Work Anniversaries
- **A clone of the birthday bot, keyed off HIRE DATE instead of birth date.**
  `anniversaries/` mirrors `birthdays/` file for file (CLI runner, `run.sh`,
  `install.sh`, systemd timer, `discover.php`, `config.example.php`, tests) with
  its own config keys, state file, heartbeat, lock, log and timer — the two
  timers can fire in the same minute, and a shared JSON state file would mean
  each read-modify-write could drop the other's record. Page `#/anniversaries`
  (`api/anniversaries.php`, `public/js/anniversaries.js`, laurel-green
  `--anniversary` theme); settings resolve through `lib/anniversary_config.php`
  in the same three layers as the birthday bot (defaults ← `data/
  anniversary_config.php` ← `api_config` rows keyed `anniversary_*`).
- **SHARED with the birthday bot on purpose: `birthdays/lib/slack_client.php`
  and `birthdays/lib/gif_source.php`.** Neither contains anything
  birthday-specific — one is Slack transport, the other a seeded GIF picker — so
  one copy means a fix to the retry classifier or the customize fallback lands
  in both. `SlackClient`'s constructor takes a `$configHint` so its "no token"
  error names the right page. `GifSource`'s own `DEFAULT_GIFS`/
  `DEFAULT_SEARCH_TERMS` are birthday ones, so `AnniversaryConfig::load()` fills
  BOTH keys with `ANNIV_DEFAULT_*` — a birthday GIF must never turn up on an
  anniversary post.
- **THE HIRE-DATE COLUMN IS `DateOfHire` — VERIFIED at the venue Aug 2026** via
  `anniversaries/discover.php`, so the shipped default roster query is correct
  as-is and needs no edit. Measured on `dbo.Employees` (1,547 rows): 1,532
  populated, years 1993-2026, ZERO future-dated, and **zero rows where it equals
  `DateOfBirth`** — that last one is the check that matters, since a hire date
  and a date of birth are both datetimes on the same table and picking the wrong
  one would post "Happy 41st anniversary" to a public channel. `EmpStatus` is
  decoded from `dbo.EmployeeStatus`: 1 Active (193), 2 Suspended (4),
  3 Terminated (1,350); `DateOfTerminate` agrees with it (no active row carries
  one). Do not re-litigate this without new evidence. If a FUTURE install
  disagrees, the failure is loud ("Invalid column name") rather than a wrong
  post, and `annivColumnHint()` points at the probe.
- **`max_celebrants` defaults to 25 here, NOT the birthday bot's 12, and the
  difference is the whole point.** Twelve people sharing a BIRTHDAY means a
  broken query; twelve sharing a HIRE DATE is just how a seasonal venue staffs
  up — this roster has cohorts of 24, 13, 13, 12 and 11 on single spring dates.
  Set the guard below the biggest cohort and the bot refuses to post on the
  busiest anniversary of the year, every year, and records a failure for it.
  What the guard actually catches is a placeholder date that never reached
  `ignore_hire_dates`. `discover.php` measures the largest CURRENT-staff cohort
  and recommends a value, and reports every distribution against current staff
  rather than the whole table (88% of which is leavers).
- **Year zero is not an anniversary.** Somebody hired this morning matches
  today's month and day exactly; `min_years` floors at 1 and the UI will not go
  below it. This is the anniversary equivalent of the birthday bot's sentinel
  guard, and for the same reason — a 1900-01-01 placeholder here would post
  "126 years", not just the wrong day.
- **Years of service ARE the message**, unlike the birthday bot where an age or
  a birth year is forbidden. Placeholders: `{names} {count} {venue} {years}
  {year_label} {ordinal} {s}`. On a SHARED day the people have different
  numbers, so `{names}` carries each person's count inline ("Robin (7 years) and
  Casey (1 year)"), `{years}` becomes the COMBINED total, and `{ordinal}`
  resolves to nothing — the API rejects `{ordinal}` in the multi pools rather
  than letting a message silently lose a word.
- **Milestone years get their own pools** (`milestone_greetings` /
  `milestone_flavors`, default years 1/5/10/…/50), applied ONLY when a single
  person is being congratulated — with several celebrants a milestone template
  would be shouting on behalf of whoever is listed first. `post_separately`
  therefore also turns milestone wording on for everybody. Every milestone
  flavour line must be true at the SMALLEST milestone as well as the largest:
  "that predates half the games on this floor" reads well at 20 years and
  absurdly at 1, and the pool is picked by milestone-ness, not by size.
  `celebrate_years = milestones` posts ONLY those years; an EMPTY
  `milestone_years` list is honoured as "no milestones" rather than silently
  substituting the defaults, so `--check` and the page both call out the
  milestone-only + empty-list combination that can never post.
- `annivMessageConfig()` is the single place that lists which settings shape a
  message — same rule and same reason as `bdayMessageConfig()`. Add a wording
  setting there, never at a call site.
- **The page's main list is the WHOLE roster, not a 60-day window**
  (`GET /api/anniversaries/roster`, `annivApiRosterList()`). One row per person
  the roster query returns, sortable on every column and filterable by time
  range (next 7/30/90 days, this/next month, this/next quarter, rest of year,
  last 30/90 days, earlier this year, custom, or everyone), by name, and by
  milestone / bot-stays-quiet. **ONE roster read per page load** — the range,
  sort, search and CSV are client-side over that payload, the Item Watch rule,
  because a roster read is an MSSQL round trip behind an 8s connect and a 30s
  query timeout. The page no longer calls `/upcoming` at all (that endpoint
  still exists and still works; the CLI's `--list` is its remaining consumer).
  Four properties that are the point of it:
  - **Two dates per person, never merged**: `next_date` (the calendar answer)
    beside `post_date` (what the bot will actually do, after `min_years`,
    milestone-only mode and the leap rule). `post_date` NULL renders as
    "Never again" **in words with the reason** — that silence is otherwise
    invisible, and one merged column is how the page would start answering
    "why didn't Slack mention Dana?" wrongly, 193 times.
  - **"Complete" means complete over TIME, not over the payroll.** Same
    `annivApiRoster()`, same operator-editable `roster_sql`, no second query and
    no "include former staff" switch — widening that WHERE clause to fill this
    page is the failure RosterGuard exists to warn about (193 current staff of
    1,547 rows), and a page headed "everyone" showing 1,547 rows looks exactly
    like the feature working. So the guard's verdict and the oldest hire date
    render BESIDE the headcount, which reads "N people the roster query
    returns", never "N employees".
  - **What reaches the browser is an allowlist.** `email` and `slack_id` are
    absent from the row entirely (not hidden client-side); `emp_no` and the
    opted-out names go only to `anniversaries_manage`, scrubbed server-side.
    `hire_date` goes to everyone deliberately — `years` + `next_date` already
    determine it, and it is the column that catches a `DateOfHire`/`DateOfBirth`
    mix-up. A unit test pins the exact key list of `annivRosterRows()` rows, and
    another feeds a row carrying `SSN`/`PasswordHash` and asserts none of it
    survives: `roster_sql` is operator-editable and `assertReadOnly()` permits
    `SELECT *`.
  - **It predicts the day the bot will REFUSE.** `shared` counts how many people
    post on the same date; over `max_celebrants` the row says so. A seasonal
    venue hires in cohorts (24 people on one spring date here), so that is a
    real, dated, foreseeable silence — and this is the first surface that can
    see all 366 days at once.
  A **"Not on the list"** panel names the rows the normaliser dropped and why
  (`collect_dropped`, OPT-IN — the daily run must not hold 1,350 leavers in
  memory to discard them). Data-quality buckets are shown to anyone who can see
  the page; the `excluded` bucket is `anniversaries_manage` only and labelled
  as an opt-out rather than a defect, echoing which rule matched so a typo'd
  `exclude_names` entry is visibly matching nobody.
  Pure date logic lives in `anniv_lib.php` (`annivObservedDate`,
  `annivNextAnniversary`, `annivPrevAnniversary`, `annivNextCelebrated`,
  `annivYearsCompleted`, `annivRosterRows`, `annivDaysBetween`) so the page and
  Slack can never drift about somebody's year count — the `annivMessageConfig()`
  rule again. Two bounds worth keeping: the year search is **+8, not +4**
  (leap years are 8 apart across a non-leap century, and a tighter bound tells a
  real person the bot will never mention them again), and `annivDaysBetween`
  works off UTC midnights because a local-time subtraction across a DST
  boundary loses or gains a day.
- Audit rows: source `anniversaries`, actions `anniversary_posted` /
  `anniversary_failed`. Keep both `api/logs.php` filter allowlists and the
  `public/js/logs.js` dropdowns in sync. NOTE a pre-existing gap this change did
  not touch: the page's own audit actions (`anniversary_settings` /
  `anniversary_demo` / `anniversary_test_slack`, written under source `manual`)
  are in neither allowlist, so they are recorded but cannot be filtered for.
- Gates: `view_anniversaries` (page, in `PAGE_PERMISSIONS`) and
  `anniversaries_manage`. `migration_anniversaries_v1` grants both to roles
  holding `birthdays_manage` (the people who configure one Slack bot are the
  people who configure the other) and runs AFTER `migration_birthdays_v1` so
  that source key exists on a fresh install. Keep the keys in sync across
  `Auth::PAGE_PERMISSIONS`, settings.js `pagePermissionKeys`, and app.js
  `PERMISSION_AREAS` / `SECTION_AREAS` / `LEGACY_ACCESS`.
- `/api/health` reports the heartbeat under `anniversaries`, and like
  `birthdays` it NEVER moves the top-level `status` — an optional accessory
  that pauses nothing must not be able to report the scheduler as degraded. A
  missing heartbeat means "not installed", not "unhealthy".
- **`lib/roster_guard.php` is SHARED by both bots** and guards the worst failure
  either has: both put employee names in a public channel, and the ONLY thing
  between "today's celebrants" and "everyone who ever worked here" is the WHERE
  clause of an operator-editable query — 193 current staff out of 1,547 rows on
  this venue. Both defaults carry `EmpStatus = 1 AND DateOfTerminate IS NULL`
  and are otherwise byte-identical; neither bot caches the roster on the daily
  path (`TodayCache` is the dashboard strip only), so every run re-reads it.
  `RosterGuard::employmentFilter()` reads the WHERE clause — comments stripped,
  SELECT list ignored, since neither can limit rows — and reports which columns
  enforce it, surfaced as a **Still employed** row in both `--check`s and on
  both pages, and as a line in every run's log. It is a WARNING, not a refusal:
  the match is a heuristic (a venue can filter through a join no word list will
  catch), and a false alarm costs a log line where refusing would cost a real
  greeting. The one hard refusal stays discover.php's
  `TODO_CONFIRM_EMPLOYMENT_FILTER` marker, which is not a guess. It replaced a
  check that only asked whether the word WHERE appeared anywhere — so
  `WHERE DateOfHire IS NOT NULL` passed silently.
- **Both bots' systemd units are written by `deploy/write-bot-units.sh`**, called
  by `update.sh` (every deploy) AND by `anniversaries/install.sh` — the same
  single-writer arrangement as `write-fpm-unit.sh` / `write-daily-unit.sh`, and
  for the same reason. Two rules it exists to enforce: (1) the SERVICE unit is
  rewritten every deploy because it carries the install path and the container
  image — which must be the **pdo_dblib overlay**, since both bots read the
  roster from MSSQL (the stock `php:fpm` trap that froze the daily rollup for
  six weeks); (2) the TIMER is **never overwritten once it exists**, because it
  carries only the schedule, and rewriting it would silently move a posting
  time the operator chose back to a default. Passing an `HH:MM` argument is the
  only thing that rewrites a timer. The writer also pins the APP's timezone
  onto each `OnCalendar` line when the host zone differs and systemd is 252+ —
  never convert to a fixed UTC offset, it breaks at every DST changeover.
  `update.sh` enables a bot's timer only when `--is-configured` says a Slack
  token AND channel exist (a silent, network-free probe on both bots); enabling
  one for an unconfigured bot would post a failed run and an audit row every
  morning. `anniversaries/systemd/` no longer exists — the writer IS the source.
- **The Command Center strip** (`#dash-celebrations` in `public/js/dashboard.js`,
  `public/css/components/celebrate-strip.css`) puts today's BIRTHDAYS and today's
  ANNIVERSARIES under the dashboard header as one row: a group per kind, a chip
  per person, each group linking to its own page. Fed by
  `GET /api/birthdays/today` + `GET /api/anniversaries/today`. Five properties,
  all deliberate:
  - it renders NOTHING on the days nobody is celebrating (no empty state above
    the fold), and each group disappears independently;
  - it never surfaces its own failures there (a roster that can't be read just
    means no group — an optional accessory must not put a red banner on the
    floor's main screen);
  - it is the SAME selection each bot posts (same leap rule, opt-outs,
    `min_years`, milestone mode), so nobody asks why Slack stayed quiet about
    somebody listed there. The corollary: in milestone-only mode an ordinary
    third year appears in neither place;
  - **a birthday chip carries a NAME AND NOTHING ELSE** — no age, no birth year,
    not even a field for one, for the same reason the greeting is forbidden from
    printing either. Years of service are the opposite case and only anniversary
    chips carry a number;
  - it does NOT cost a roster read per poll. The dashboard polls every 30s and
    both endpoints sit on a 5000-row MSSQL query behind a 30s timeout, so the
    browser refetches at most every 10 min (`CELEBRATE_REFRESH_MS`) and the
    server memoises via `lib/today_cache.php`.
- **`lib/today_cache.php` is SHARED by both bots** (same rationale as
  `slack_client.php`/`gif_source.php`): `TodayCache::TTL_OK` 30 min,
  `TTL_FAIL` 10 min — **caching the FAILURE is the point**, or an unreachable
  database is retried by every open dashboard on every poll, each waiting out
  the connect timeout. Entries are keyed by a per-bot SIGNATURE
  (`annivTodaySignature()` / `bdayTodaySignature()`) of every setting that
  decides who counts, so a settings change invalidates outright instead of
  leaving a wrong chip up for the rest of the TTL — add a setting there when
  you add one that changes the answer. A negative age (clock jumped back) is a
  miss, not an immortal entry. Pinned by
  `anniversaries/tests/test_today_cache.php` (needs config.php but no DB —
  config.php is constants only), which covers BOTH bots' signatures.
- **The milestone chip keeps the SAME background as an ordinary chip** and is
  lifted by a border + halo + a star instead. Filling it with the hue looked
  right on dark and was backwards on light, where the ordinary chips are white
  and a green-tinted milestone chip was the DIMMEST thing in the row it is
  supposed to lead. The star also means the distinction is not carried by two
  shades of green alone. Light-mode `--anniversary` is `#4a7016` (5.9:1 on
  white) rather than the more obvious `#5f8f22`, which measures 3.9:1 and fails
  AA for the 0.72rem uppercase labels; light-mode `--birthday` moved from
  `#b3661a` (4.4:1) to `#9c580f` (5.6:1) for the same reason, and gained the
  `--birthday-rgb` override it had always been missing (every tinted background
  on the Birthdays page was being washed in the DARK-mode amber).

### Tag Board & PWA
- Tag Board (`#/tags`, `public/js/tags.js`, `public/css/pages/tags.css`) is the
  phone-first page for floor staff to tag games OUT of service / back IN
  ("tagged out" = operationStatus `outOfService`, which the scheduler skips
  until cleared). Top cards list what's tagged out / paused; tappable summary
  chips + a chip bar filter the searchable all-games list; every row carries
  one obvious 44px+ action button behind an App.confirm step, AND the whole
  row is tappable — it opens a bottom ACTION SHEET (game name + full-width
  buttons; choosing there skips the extra confirm, the sheet itself being the
  deliberate step). Accounts without `manual_control` get an explicit
  view-only banner instead of a silently button-less board. The SPA shell is
  served `Cache-Control: no-cache` so phones revalidate the HTML and pick up
  deploys immediately (assets stay cached via ?v=mtime). Auto-refreshes
  (~25s, visibility-aware) so phones on the floor converge. Reuses the Games
  page backend: `GET /api/games` (list) + `PATCH /api/games` (status), plus
  ONE purpose-built endpoint, `POST /api/games/unpause-all` (the Paused
  card's "Unpause all" button; gate `manual_control`). Unpause-all must NOT
  be a bare per-game patch: enforcement re-pauses schedule-paused games
  within ~a minute, so for every ACTIVE pause group containing a paused game
  it runs the dashboard's `Scheduler::executeImmediate(group,'unpause',
  'manual')` (sets the manual override that holds until the group's next
  scheduled transition, and skips outOfService members — tagged-out stays
  tagged out), then direct-patches paused games in no active group, all
  under one scheduler lock. Summary audit row: action `unpause_all`.
- Visibility key `view_tags` (in `Auth::PAGE_PERMISSIONS`, grouped under
  "Pages" in the role editor; also in settings.js `pagePermissionKeys` and
  app.js PERMISSION_AREAS/SECTION_AREAS/LEGACY_ACCESS — keep all in sync).
  One-time migration `migration_view_tags_v1` granted it to roles holding
  `view_games`. The games GET gate (`requireAnyAccess`) includes `view_tags`
  so a tag-board-only role can read the list; tag actions still require
  `manual_control` (the PATCH gate, unchanged).
- Manual game-status PATCHes are now audit-logged: source `game-status`,
  actions `game_tagged_out` / `game_enabled` / `game_paused`, with game
  name + actor + upstream error on failure (both logs.php filter allowlists
  include them).
- PWA: `public/manifest.webmanifest` (start_url `./#/tags` — installing is a
  Tag Board gesture) + `public/sw.js` + generated PNGs in `public/icons/`.
  index.php serves `/sw.js` and `/manifest.webmanifest` at the app ROOT
  (worker scope must cover the app; `/public/sw.js` would scope to /public/)
  with `Cache-Control: no-cache`; app.js registers the worker on boot. The
  service worker is deliberately conservative: it NEVER intercepts `/api/`
  (live state/auth/CSRF untouched), navigations are network-first with the
  last good shell as offline fallback only, and `/public/` assets are
  cache-first (safe — asset URLs carry `?v=mtime`), evicting stale versions
  of the same path. Do not add API caching to it.

### Scheduling Engine
- **The host clock's TIMEZONE does not affect pause/unpause.** Verified on the
  venue Aug 2026 when the birthday timer exposed a host-UTC / app-Eastern gap:
  `pause-groups-watchdog.timer` is `OnCalendar=minutely` (no clock time, so the
  system zone is irrelevant), and `Scheduler::enforceCurrentStates()` sets the
  APP timezone then computes desired state live from the `schedules` table
  (day-of-week + HH:MM vs start_time/end_time) every minute. So machine on/off
  has never read the system zone. The `at`-job layer is INERT on this install —
  `hasAtScheduler()` needs `at`+`atrm` on PATH and the php-fpm container ships
  neither; measured 181 planned actions, 0 with an `at_job_id`, ever. Net: all
  transitions come from the per-minute watchdog (so up to ~60s late, never
  wrong). What the UTC host DID cost: `pause-groups-daily.timer` carried a bare
  `OnCalendar=*-*-* 00:05:00`, and systemd fires that on the SYSTEM zone — so it
  ran at 00:05 UTC = **20:05 Eastern the PREVIOUS day**. **This was written off
  here as "harmless while `at` is absent". It was harmless for pausing and
  NOT harmless for reporting, which is the mistake to learn from: the
  consequence was measured on the wrong subsystem.** `cron.php` sets the app
  timezone, so a run at 20:05 Eastern computes `$today` as that previous day,
  and `refreshVenueDailyStatsRecent()` never writes the running day — so the
  newest day it could reach was the day before THAT. A perfectly healthy nightly
  chain still left every reporting figure **two days behind**, permanently, and
  no amount of successful runs could close it (venue, Sep 6 2026: newest
  complete day Sep 4 at best, and the operator quite reasonably read that as
  broken). **`deploy/write-daily-unit.sh` now writes the timer with the APP's
  timezone pinned** (`OnCalendar=*-*-* 00:05:00 America/New_York`, systemd 252+,
  the same mechanism `write-bot-units.sh` uses and verified with
  `systemd-analyze calendar`: unpinned next-elapse 00:05 UTC, pinned 04:05 UTC =
  00:05 local). The run now lands after LOCAL midnight, where "yesterday" is a
  complete day. Never substitute a fixed UTC offset — it breaks at every DST
  changeover. Planning also improves as a side effect: `planDay()` now plans a
  day that is starting rather than one with four hours left.
- Schedule windows = active (unpaused) hours. Outside windows = paused.
- Priority: manual override > schedule override > recurring schedule
- `planDay()` computes transition points, resolves conflicts, deduplicates
- Missed-action optimization: only latest per group executed, earlier superseded (status 3)
- Concurrency via ONE global scheduler lock (`Scheduler::acquireLock()/releaseLock()`,
  re-entrant per process). cron.php, cron_watchdog.php, run_action.php AND the web
  entry points (manual actions, per-request enforcement) all take it — never
  fopen/flock LOCK_FILE directly. The watchdog holds it only for its action
  phase and releases before the slow transaction poll.
- `executeStateChange()` patches both games AND kiosks for a group in one
  invocation — kiosks share the GameOperationStatus enum (enabled/paused/outOfService).
  Kiosk patching is best-effort; failure does not roll back game changes.
- Per the kiosk API spec, kiosks reporting no `operationStatus` ("unknown")
  must NOT be pause-controlled — the scheduler skips them automatically.

### Security
- Passwords: bcrypt cost 12, auto-rehash
- CSRF: 256-bit token, `X-CSRF-Token` header, timing-safe validation
- Encryption at rest: AES-256-CBC + HMAC-SHA256 for API credentials
- CLI-only guards on cron scripts
- Input validation via Validator class (throws RuntimeException)
- Roles are DATA (the `roles` table, edited via /api/roles + Settings UI);
  permissions are CODE (`Auth::PERMISSIONS` catalog — 25 keys incl.
  view_revenue, manual_control, reader_groups_manage, promotions_manage,
  items_manage, view_tags, data_explorer, view_birthdays, birthdays_manage,
  view_anniversaries, anniversaries_manage). A
  read-only "Viewer"
  role (all pages + analytics + view_revenue + cards + view_logs) is seeded
  once as a normal custom role — fully editable/deletable in Settings.
  Mutation buttons are also hidden client-side for roles lacking the
  relevant permission (server re-checks regardless).
- Every sidebar section is hideable per role (and per user via the
  grant/deny override editor): the seven operational pages have view_* keys
  (`Auth::PAGE_PERMISSIONS`, grouped as "Pages" in the role editor); the
  reporting pages use their existing keys (analytics, cards, view_logs,
  settings). Hiding removes the nav item, bounces the route
  (`App.SECTION_AREAS` drives nav + guard + `App.defaultHash()` landing;
  `#/no-access` covers roles with nothing enabled), and blocks reads:
  shared GET endpoints use `Auth::requireAnyAccess([...])` dependency sets
  (e.g. groups GET allows view_groups|view_dashboard|view_schedules|
  view_overrides|the manage keys) so a visible section always has the data
  it renders, and data closes only when every section needing it is hidden.
  A one-time migration (`migration_view_keys_v1`) granted all six view keys
  to every existing role so the upgrade changed nobody's access.
  `Auth::hasPermission()/canAccess()` resolve
  through the user's role; admin bypasses and is locked against edit/delete.
  The client gets the resolved permission list injected into
  `APP_CONFIG.user.permissions` (and login/status responses) —
  `App.canAccess()` reads it (LEGACY_ACCESS fallback for stale sessions).
  Non-admins can only assign roles whose permissions are a subset of their
  own (`Auth::canAssignRole`). Unknown role slugs resolve to ZERO permissions.
- Sessions re-validate role + is_active from the DB every ~60s, so role
  changes / deactivation / deletion apply without waiting for re-login.
- Admin accounts can only be modified/deleted by admins; last-admin
  demotion/deactivation/deletion is blocked. Card PIN checks are
  audit-logged and rate-limited (15 / 10 min per user).

### Testing
- No suite-wide test runner; a few pure helpers carry their own assertions,
  each runnable standalone with no database and no network:
  - `php tests/test_rollup_health.php` — the rollup-freshness verdict
    (`Reporting::classifyRollup`): the tolerance boundaries, and the cases that
    separate a stopped nightly job from a venue that was simply closed
  - `php birthdays/tests/*.php`, `php anniversaries/tests/*.php` — the two Slack
    bots' date/roster/message logic (310+ assertions)
- Manual smoke testing via install.php, cron.php, UI flows
- `php -l` for syntax checking across all PHP files

### Running Locally
```bash
php -S localhost:8080 index.php   # Built-in PHP server
# Or with Apache: .htaccess handles URL rewriting
```

### Cron Setup
```bash
* * * * * /usr/bin/php /path/to/cron_watchdog.php >> /path/to/data/watchdog.log 2>&1
5 0 * * * /usr/bin/php /path/to/cron.php >> /path/to/data/cron.log 2>&1
```
