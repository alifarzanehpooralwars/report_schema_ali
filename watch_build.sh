#!/usr/bin/env bash
# =============================================================================
#  watch_build.sh — resilient live LaTeX build watcher & multi-remote publisher
#
#  Author      : Ali Farzanehpoor Alwars  <a.farzaneh@desy.de>
#  Affiliation : Deutsches Elektronen-Synchrotron DESY
#  Timezone    : Europe/Berlin (all timestamps)
#  Target      : /home/ali/report_schema_ali/main.tex
#
#  Remotes
#     desy    git@gitlab.desy.de:farzaneh/report_schema_ali.git
#     github  git@github.com:alifarzanehpooralwars/report_schema_ali.git
#     desy-sns:report_schema_ali   (rclone / WebDAV snapshots)
#
#  Offline policy
#     Every remote is attempted independently with a short timeout.
#     A remote that cannot be reached is put on a PENDING list and retried
#     on a timer. Nothing blocks, nothing aborts. When the VPN comes back
#     the pending pushes flush by themselves on the next retry tick.
#
#  Usage
#     ./watch_build.sh              # build once, then watch
#     ./watch_build.sh --no-build   # watch only
#     ./watch_build.sh --help
#
#  Dependencies
#     sudo apt install inotify-tools latexmk texlive-latex-extra \
#                      poppler-utils zip git rclone
# =============================================================================
set -uo pipefail

# ------------------------------------------------------------------ clock ----
export TZ="${REPORT_TZ:-Europe/Berlin}"

# --------------------------------- CONFIG ------------------------------------
PROJECT_DIR="${PROJECT_DIR:-/home/ali/report_schema_ali}"
MAIN_TEX="${MAIN_TEX:-main.tex}"

BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/.build-logs}"
VERSIONS_TSV="${LOG_DIR}/versions.tsv"
BUILD_LOG="${LOG_DIR}/latexmk.log"
SESSION_LOG="${LOG_DIR}/watcher.log"

# --- local SSD snapshots ------------------------------------------------------
BACKUP_ENABLE="${BACKUP_ENABLE:-1}"
BACKUP_ROOT="${BACKUP_ROOT:-/home/ali/backups/report_schema_ali}"
KEEP_BACKUPS="${KEEP_BACKUPS:-15}"

# --- git / remotes ------------------------------------------------------------
GIT_ENABLE="${GIT_ENABLE:-1}"
GIT_PUSH="${GIT_PUSH:-1}"
GIT_BRANCH="${GIT_BRANCH:-main}"

GITLAB_ENABLE="${GITLAB_ENABLE:-1}"
GITLAB_REMOTE="${GITLAB_REMOTE:-desy}"
GITLAB_URL="${GITLAB_URL:-git@gitlab.desy.de:farzaneh/report_schema_ali.git}"

GITHUB_ENABLE="${GITHUB_ENABLE:-1}"
GITHUB_REMOTE="${GITHUB_REMOTE:-github}"
GITHUB_URL="${GITHUB_URL:-git@github.com:alifarzanehpooralwars/report_schema_ali.git}"

SNS_ENABLE="${SNS_ENABLE:-1}"
SNS_REMOTE="${SNS_REMOTE:-desy-sns}"
SNS_PATH="${SNS_PATH:-report_schema_ali}"
SNS_MODE="${SNS_MODE:-snapshots}"        # snapshots | mirror

# --- resilience timing (seconds) ---------------------------------------------
PUSH_MIN_INTERVAL="${PUSH_MIN_INTERVAL:-120}"   # min gap between network attempts
RETRY_TICK="${RETRY_TICK:-10}"                  # watcher wake-up period
GIT_TIMEOUT="${GIT_TIMEOUT:-45}"                # hard cap per git push
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-6}" # per-connection cap
RCLONE_CONTIMEOUT="${RCLONE_CONTIMEOUT:-10}"
RCLONE_TIMEOUT="${RCLONE_TIMEOUT:-30}"

export GIT_SSH_COMMAND="ssh -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} \
-o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=2"

# --- commit identity ----------------------------------------------------------
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Ali Farzanehpoor Alwars}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-a.farzaneh@desy.de}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# --- watcher ------------------------------------------------------------------
WATCH_REGEX="${WATCH_REGEX:-\.(tex|bib|sty|cls|bst)$}"
DEBOUNCE="${DEBOUNCE:-0.35}"
LATEXMK_FLAGS=(-pdf -g -interaction=nonstopmode -file-line-error -synctex=1)
CORES="$(nproc --all 2>/dev/null || echo 1)"

# --------------------------------- COLOURS -----------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi

# ----------------------------------- STATE -----------------------------------
STATE="idle"
BUILD_NO=0
REV=0
SESSION_BUILDS=0
SESSION_OK=0
SESSION_FAIL=0
LAST_START="--:--:--"
LAST_END="--:--:--"
DUR_S="0.00"
WARNINGS=0
ERR_LINE="—"
PDF_PAGES="—"
PDF_SIZE="—"
LAST_SAVE="—"
LAST_FILE="—"
LAST_BACKUP="—"
OPT_NO_BUILD=0

PENDING=""                 # space separated: gitlab github sns
PUSH_OK=()
PUSH_FAIL=()
LAST_ATTEMPT_EPOCH=0
LAST_FLUSH_HUMAN="—"
DRAW_SIG=""

# --------------------------------- HELPERS -----------------------------------
usage() {
    cat <<EOF
DESY report live-build watcher — Ali Farzanehpoor Alwars <a.farzaneh@desy.de>
Timezone: ${TZ}

  ./watch_build.sh [options]

  --no-build    start the watcher without an initial compilation
  -h, --help    show this help

Remotes: DESY GitLab (desy), GitHub (github), DESY Sync&Share (desy-sns).
Unreachable remotes are queued and retried automatically.

Environment overrides: PROJECT_DIR, MAIN_TEX, BUILD_DIR, LOG_DIR,
BACKUP_ROOT, KEEP_BACKUPS, BACKUP_ENABLE, GIT_ENABLE, GIT_PUSH,
GITLAB_*, GITHUB_*, SNS_*, PUSH_MIN_INTERVAL, RETRY_TICK,
GIT_TIMEOUT, SSH_CONNECT_TIMEOUT, RCLONE_*, WATCH_REGEX, DEBOUNCE, REPORT_TZ
EOF
}

die() { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

now_iso()   { date -Is; }
now_clock() { date '+%H:%M:%S'; }

log_session() {
    printf '%s\t%s\n' "$(now_iso)" "$*" >> "$SESSION_LOG"
}

# --- pending list -------------------------------------------------------------
pending_add() {
    case " $PENDING " in *" $1 "*) return 0 ;; esac
    PENDING="${PENDING:+$PENDING }$1"
}
pending_del() {
    [[ -z "$PENDING" ]] && return 0
    PENDING="$(printf '%s\n' $PENDING | grep -vx -- "$1" | tr '\n' ' ' | sed 's/ *$//')"
}
pending_clear() { PENDING=""; }

mb() { awk -v b="${1:-0}" 'BEGIN{printf "%.4f MB", b/1048576}'; }

require_tools() {
    local missing=()
    command -v inotifywait >/dev/null 2>&1 || missing+=("inotify-tools")
    command -v latexmk     >/dev/null 2>&1 || missing+=("latexmk")
    command -v zip         >/dev/null 2>&1 || missing+=("zip")
    (( ${#missing[@]} > 0 )) \
        && die "missing packages: ${missing[*]}  ->  sudo apt install ${missing[*]}"
    [[ -f "${PROJECT_DIR}/${MAIN_TEX}" ]] \
        || die "cannot find ${PROJECT_DIR}/${MAIN_TEX}"
}

init_state_from_log() {
    if [[ -s "$VERSIONS_TSV" ]]; then
        REV=$(awk -F'\t' 'NR>1 && $2+0>m {m=$2+0} END{print m+0}' "$VERSIONS_TSV")
        BUILD_NO=$(awk -F'\t' 'NR>1 && $3+0>m {m=$3+0} END{print m+0}' "$VERSIONS_TSV")
    fi
    REV="${REV:-0}"; BUILD_NO="${BUILD_NO:-0}"
}

# --- one-time housekeeping: stray root-level artefacts ------------------------
prune_artefacts() {
    local f
    for f in main2.pdf main2.tex t.pdf main.pdf; do
        [[ -e "${PROJECT_DIR}/${f}" ]] || continue
        ( cd "$PROJECT_DIR" \
          && git ls-files --error-unmatch "$f" >/dev/null 2>&1 \
          && git rm -q --cached "$f" >/dev/null 2>&1 ) || true
    done
    local gi="${PROJECT_DIR}/.gitignore"
    touch "$gi"
    for pat in '/main.pdf' 'main2.*' 't.pdf'; do
        grep -qxF -- "$pat" "$gi" || printf '%s\n' "$pat" >> "$gi"
    done
}

# ---------------------------------- VIEW -------------------------------------
build_frame() {
    local st stc
    case "$STATE" in
        building) st="◐  building …"; stc="$C_YEL" ;;
        ok)       st="✔  success";    stc="$C_GRN" ;;
        failed)   st="✖  failed";     stc="$C_RED" ;;
        *)        st="·  idle";       stc="$C_DIM" ;;
    esac

    local pend
    if [[ -z "$PENDING" ]]; then
        pend="${C_GRN}all delivered${C_RESET}"
    else
        pend="${C_YEL}${PENDING}${C_RESET} ${C_DIM}(retrying every ${PUSH_MIN_INTERVAL}s)${C_RESET}"
    fi

    printf '%s\n' "${C_CYN}════════════════════════════════════════════════════════════════════════${C_RESET}"
    printf ' %sDESY · Metadata Schema report%s\n' "$C_BOLD" "$C_RESET"
    printf ' %sAli Farzanehpoor Alwars · a.farzaneh@desy.de · %s%s\n' \
           "$C_DIM" "$TZ" "$C_RESET"
    printf '%s\n' "${C_CYN}════════════════════════════════════════════════════════════════════════${C_RESET}"
    printf ' %-11s %s\n' "project"  "$PROJECT_DIR"
    printf ' %-11s %s  %s(inotify: close_write · moved_to — not on keystroke)%s\n' \
           "source" "$MAIN_TEX" "$C_DIM" "$C_RESET"
    printf ' %-11s %s\n' "engine"   "latexmk + pdflatex · ${CORES} cores"
    printf ' %-11s %s\n' "outputs"  "build/${MAIN_TEX%.tex}.pdf · .build-logs/versions.tsv"
    printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────────────────${C_RESET}"
    printf ' %-11s %s    %s\n' "state" "${stc}${st}${C_RESET}" \
           "${C_DIM}build #${BUILD_NO} · revision v${REV}${C_RESET}"
    printf ' %-11s %s → %s  (%s s)\n' "compiled" "$LAST_START" "$LAST_END" "$DUR_S"
    printf ' %-11s %s pages · %s\n' "pdf" "$PDF_PAGES" "$PDF_SIZE"
    printf ' %-11s %s\n' "warnings" "$WARNINGS"
    printf ' %-11s %s\n' "errors"   "$ERR_LINE"
    printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────────────────${C_RESET}"
    printf ' %-11s %s · %s\n' "last save" "$LAST_SAVE" "$LAST_FILE"
    printf ' %-11s %s\n' "snapshot"   "$LAST_BACKUP"
    printf ' %-11s ok:[%s]  fail:[%s]\n' "last push" \
           "${PUSH_OK[*]:-—}" "${PUSH_FAIL[*]:-—}"
    printf ' %-11s %s  %s(last attempt %s)%s\n' "queue" "$pend" "$C_DIM" "$LAST_FLUSH_HUMAN" "$C_RESET"
    printf ' %-11s %s\n' "session" \
           "${SESSION_BUILDS} builds · ${SESSION_OK} ok · ${SESSION_FAIL} failed"
    printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────────────────${C_RESET}"
    printf ' %s⟳  watching …   Ctrl-C to stop%s\n' "$C_DIM" "$C_RESET"
    printf '%s\n' "${C_CYN}════════════════════════════════════════════════════════════════════════${C_RESET}"
}

draw() { printf '\033[H\033[J'; build_frame; }

draw_if_changed() {
    local sig="${STATE}|${BUILD_NO}|${PENDING}|${LAST_BACKUP}|${LAST_SAVE}|${LAST_FILE}|\
${PUSH_OK[*]:-}|${PUSH_FAIL[*]:-}|${WARNINGS}|${ERR_LINE}|${PDF_PAGES}|${PDF_SIZE}|\
${LAST_START}|${LAST_END}|${DUR_S}|${LAST_FLUSH_HUMAN}"
    [[ "$sig" == "$DRAW_SIG" ]] && return 0
    DRAW_SIG="$sig"
    draw
}

# ------------------------------- VERSION LOG ---------------------------------
record_version() {
    if [[ ! -s "$VERSIONS_TSV" ]]; then
        printf 'timestamp\trev\tbuild\tstatus\tduration_s\tpages\tpdf_bytes\tsha256_main_tex\tbackup\n' \
            > "$VERSIONS_TSV"
    fi
    local sha bytes pdf
    pdf="${BUILD_DIR}/${MAIN_TEX%.tex}.pdf"
    sha="$(sha256sum "${PROJECT_DIR}/${MAIN_TEX}" 2>/dev/null | cut -d' ' -f1)"
    bytes="$(stat -c%s "$pdf" 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(now_iso)" "$REV" "$BUILD_NO" "$STATE" "$DUR_S" \
        "$PDF_PAGES" "$bytes" "${sha:-na}" "$LAST_BACKUP" >> "$VERSIONS_TSV"
}

# -------------------------------- SNAPSHOTS ----------------------------------
make_backup() {
    (( BACKUP_ENABLE )) || return 0
    mkdir -p "$BACKUP_ROOT"
    local dest="${BACKUP_ROOT}/v${REV}_$(date +%Y-%m-%d_%H-%M-%S)_$(basename "$PROJECT_DIR").zip"
    if ( cd "$PROJECT_DIR" && zip -r -9 -q "$dest" . \
            -x 'build/*' '.git/*' '.build-logs/*' '*.aux' '*.log' '*.out' \
               '*.toc' '*.synctex.gz' '*.fls' '*.fdb_latexmk' '*.bbl' '*.blg' \
               'main2.*' 't.pdf' '/main.pdf' ); then
        LAST_BACKUP="$(basename "$dest")"
    else
        LAST_BACKUP="backup failed"
        log_session "backup FAILED -> $dest"
    fi
    ls -1t "${BACKUP_ROOT}"/*.zip 2>/dev/null \
        | tail -n +$(( KEEP_BACKUPS + 1 )) | xargs -r rm -f
}

# --------------------------------- PUBLISH -----------------------------------
_ensure_remote() {
    local name="$1" url="$2"
    ( cd "$PROJECT_DIR" || exit 1
      if git remote get-url "$name" >/dev/null 2>&1
         then git remote set-url "$name" "$url"
         else git remote add    "$name" "$url"; fi )
}

push_gitlab() {
    _ensure_remote "$GITLAB_REMOTE" "$GITLAB_URL"
    timeout "$GIT_TIMEOUT" git -C "$PROJECT_DIR" push -q \
        "$GITLAB_REMOTE" "HEAD:${GIT_BRANCH}" >/dev/null 2>&1
}

push_github() {
    _ensure_remote "$GITHUB_REMOTE" "$GITHUB_URL"
    timeout "$GIT_TIMEOUT" git -C "$PROJECT_DIR" push -q \
        "$GITHUB_REMOTE" "HEAD:${GIT_BRANCH}" >/dev/null 2>&1
}

push_sns() {
    command -v rclone >/dev/null 2>&1 || return 1
    local rc=0
    if [[ "$SNS_MODE" == "mirror" ]]; then
        rclone sync "$PROJECT_DIR" "${SNS_REMOTE}:${SNS_PATH}" \
            --exclude 'build/**' --exclude '.git/**' --exclude '.build-logs/**' \
            --create-empty-src-dirs --quiet \
            --contimeout "${RCLONE_CONTIMEOUT}s" --timeout "${RCLONE_TIMEOUT}s" \
            --retries 1 --low-level-retries 1 || rc=$?
    else
        [[ "$LAST_BACKUP" == *.zip ]] || return 0   # nothing to send yet
        rclone copy "${BACKUP_ROOT}/${LAST_BACKUP}" \
            "${SNS_REMOTE}:${SNS_PATH}/snapshots" --quiet \
            --contimeout "${RCLONE_CONTIMEOUT}s" --timeout "${RCLONE_TIMEOUT}s" \
            --retries 1 --low-level-retries 1 || rc=$?
    fi
    (( rc == 0 ))
}

# Try every pending remote, independently. Never aborts the script.
flush_remotes() {
    [[ -z "$PENDING" ]] && return 0
    local snapshot="$PENDING" r
    PUSH_OK=(); PUSH_FAIL=()
    for r in $snapshot; do
        case "$r" in
            gitlab) if push_gitlab; then pending_del gitlab; PUSH_OK+=("gitlab")
                    else PUSH_FAIL+=("gitlab"); fi ;;
            github) if push_github; then pending_del github; PUSH_OK+=("github")
                    else PUSH_FAIL+=("github"); fi ;;
            sns)    if push_sns;    then pending_del sns;    PUSH_OK+=("sns")
                    else PUSH_FAIL+=("sns");    fi ;;
        esac
    done
    LAST_FLUSH_HUMAN="$(now_clock)"
    log_session "flush: ok=[${PUSH_OK[*]:-}] fail=[${PUSH_FAIL[*]:-}] pending=[${PENDING:-—}]"
}

maybe_flush() {
    [[ -z "$PENDING" ]] && return 0
    local t; t=$(date +%s)
    (( t - LAST_ATTEMPT_EPOCH < PUSH_MIN_INTERVAL )) && return 0
    LAST_ATTEMPT_EPOCH=$t
    flush_remotes
}

git_commit() {
    (( GIT_ENABLE )) || return 0
    ( cd "$PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1 ) || return 0
    ( cd "$PROJECT_DIR" || exit 1
      git add -A
      git diff --cached --quiet && exit 0
      git commit -q -m "build v${REV}: ${STATE} · $(date '+%Y-%m-%d %H:%M:%S %Z')" )
}

# ---------------------------------- BUILD ------------------------------------
run_build() {
    local reason="${1:-manual}"
    BUILD_NO=$(( BUILD_NO + 1 ))
    REV=$(( REV + 1 ))
    STATE="building"
    LAST_START="$(now_clock)"
    LAST_END="--:--:--"
    DUR_S="…"
    ERR_LINE="—"
    draw

    local t0 t1 rc
    t0=$(date +%s%3N)
    (
        cd "$PROJECT_DIR" || exit 1
        latexmk "${LATEXMK_FLAGS[@]}" \
                -outdir="$BUILD_DIR" \
                -e "\$max_processors = ${CORES};" \
                "$MAIN_TEX"
    ) >"$BUILD_LOG" 2>&1
    rc=$?
    t1=$(date +%s%3N)

    LAST_END="$(now_clock)"
    DUR_S=$(awk -v d=$(( t1 - t0 )) 'BEGIN{printf "%.2f", d/1000}')

    if (( rc == 0 )); then
        STATE="ok"; SESSION_OK=$(( SESSION_OK + 1 ))
    else
        STATE="failed"; SESSION_FAIL=$(( SESSION_FAIL + 1 ))
        ERR_LINE="$(grep -m1 -E '^[^ ]+\.(tex|sty|cls|bib):[0-9]+:' "$BUILD_LOG" || true)"
        [[ -z "$ERR_LINE" ]] && ERR_LINE="$(grep -m1 -E '^!' "$BUILD_LOG" || true)"
        [[ -z "$ERR_LINE" ]] && ERR_LINE="see .build-logs/latexmk.log"
        ERR_LINE="${ERR_LINE:0:74}"
    fi
    SESSION_BUILDS=$(( SESSION_BUILDS + 1 ))

    WARNINGS=$(grep -c -E 'LaTeX Warning|Package [^ ]+ Warning' "$BUILD_LOG" 2>/dev/null || true)
    WARNINGS="${WARNINGS:-0}"

    local pdf="${BUILD_DIR}/${MAIN_TEX%.tex}.pdf" bytes
    if [[ -f "$pdf" ]]; then
        PDF_PAGES="$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/{print $2}')"
        PDF_PAGES="${PDF_PAGES:-?}"
        bytes="$(stat -c%s "$pdf" 2>/dev/null || echo 0)"
        PDF_SIZE="$(mb "$bytes")"
    else
        PDF_PAGES="—"; PDF_SIZE="no pdf"
    fi

    [[ "$STATE" == "ok" ]] && make_backup

    # local record is unconditional — never depends on the network
    record_version
    git_commit

    (( GIT_PUSH )) || { log_session "build=${BUILD_NO} rev=v${REV} state=${STATE} reason=${reason} (push disabled)"; draw; return 0; }

    (( GITLAB_ENABLE )) && pending_add gitlab
    (( GITHUB_ENABLE )) && pending_add github
    (( SNS_ENABLE ))    && pending_add sns
    [[ -n "$PENDING" ]] && { LAST_ATTEMPT_EPOCH=0; maybe_flush; }

    log_session "build=${BUILD_NO} rev=v${REV} state=${STATE} dur=${DUR_S}s reason=${reason} pending=[${PENDING:-—}]"
    draw
}

# --------------------------------- WATCHER -----------------------------------
watch_loop() {
    local fname rc
    exec 3< <(inotifywait -m -q -e close_write,moved_to --format '%f' "$PROJECT_DIR" 2>/dev/null)
    while true; do
        if IFS= read -r -t "$RETRY_TICK" fname <&3; then
            [[ "$fname" =~ $WATCH_REGEX ]] || continue
            LAST_FILE="$fname"
            while IFS= read -r -t "$DEBOUNCE" _ <&3; do :; done
            LAST_SAVE="$(now_clock)"
            run_build "save: ${fname}"
            continue
        fi
        rc=$?
        if (( rc > 128 )); then                 # read timed out: normal heartbeat
            maybe_flush
            draw_if_changed
        else                                    # inotifywait died: reopen and carry on
            log_session "inotifywait exited (rc=$rc) — restarting"
            exec 3<&-
            sleep 1
            exec 3< <(inotifywait -m -q -e close_write,moved_to --format '%f' "$PROJECT_DIR" 2>/dev/null)
        fi
    done
}

# --------------------------------- CLEANUP -----------------------------------
cleanup() {
    trap - EXIT INT TERM
    printf '\033[?25h\033[0m'
    log_session "session end: ${SESSION_BUILDS} builds, ${SESSION_OK} ok, ${SESSION_FAIL} failed, pending=[${PENDING:-—}]"
    printf '\n %sSession:%s %d builds · %d ok · %d failed\n' \
           "$C_BOLD" "$C_RESET" "$SESSION_BUILDS" "$SESSION_OK" "$SESSION_FAIL"
    [[ -n "$PENDING" ]] && printf ' %sQueued (not delivered):%s %s\n' \
           "$C_YEL" "$C_RESET" "$PENDING"
    printf ' %sVersions:%s %s\n' "$C_BOLD" "$C_RESET" "$VERSIONS_TSV"
    printf ' %sSnapshots:%s %s\n\n' "$C_BOLD" "$C_RESET" "$BACKUP_ROOT"
    exit 0
}

# ---------------------------------- MAIN -------------------------------------
main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --no-build) OPT_NO_BUILD=1 ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage; die "unknown option: $arg" ;;
        esac
    done

    require_tools
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$BACKUP_ROOT"
    init_state_from_log
    prune_artefacts
    trap cleanup EXIT INT TERM

    printf '\033[2J\033[?25l'
    log_session "session start (cores=${CORES}, tz=${TZ}, project=${PROJECT_DIR})"

    draw
    (( OPT_NO_BUILD )) || run_build "startup"
    watch_loop
}

main "$@"
