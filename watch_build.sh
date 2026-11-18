#!/usr/bin/env bash
# =============================================================================
#  watch_build.sh — live LaTeX build watcher, multi-remote publisher
#
#  Author      : Ali Farzanehpoor Alwars  <a.farzaneh@desy.de>
#  Affiliation : Deutsches Elektronen-Synchrotron DESY
#  Target      : /home/ali/report_schema_ali/main.tex
#
#  Remotes
#     desy    git@gitlab.desy.de:farzaneh/report_schema_ali.git
#     github  git@github.com:alifarzanehpooralwars/report_schema_ali.git
#     desy-sns:report_schema_ali   (rclone / WebDAV snapshots)
#
#  Usage
#     ./watch_build.sh              # build once, then watch
#     ./watch_build.sh --no-build   # watch only
#     ./watch_build.sh --help
#
#  Behaviour
#     * rebuilds ONLY on CLOSE_WRITE / MOVED_TO (real Ctrl+S saves)
#     * latexmk + pdflatex, all cores
#     * single self-refreshing dashboard, no message spam
#     * per-build record in .build-logs/versions.tsv
#     * local zip snapshot after every successful build
#     * throttled push to DESY GitLab, GitHub, DESY Sync&Share
#
#  Dependencies
#     sudo apt install inotify-tools latexmk texlive-latex-extra \
#                      poppler-utils zip git rclone
# =============================================================================
set -uo pipefail

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

PUSH_MIN_INTERVAL="${PUSH_MIN_INTERVAL:-300}"
LAST_PUSH_EPOCH=0
PUSH_OK=()
PUSH_FAIL=()

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

# --------------------------------- HELPERS -----------------------------------
usage() {
    cat <<EOF
DESY report live-build watcher — Ali Farzanehpoor Alwars <a.farzaneh@desy.de>

  ./watch_build.sh [options]

  --no-build    start the watcher without an initial compilation
  -h, --help    show this help

Remotes: DESY GitLab (desy), GitHub (github), DESY Sync&Share (desy-sns)
Environment overrides: PROJECT_DIR, MAIN_TEX, BUILD_DIR, LOG_DIR,
BACKUP_ROOT, KEEP_BACKUPS, BACKUP_ENABLE, GIT_ENABLE, GIT_PUSH,
GITLAB_*, GITHUB_*, SNS_*, PUSH_MIN_INTERVAL, WATCH_REGEX, DEBOUNCE
EOF
}

die() { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

log_session() {
    printf '%s\t%s\n' "$(date -Is)" "$*" >> "$SESSION_LOG"
}

human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        echo "${bytes}B"
    fi
}

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

# ---------------------------------- VIEW -------------------------------------
build_frame() {
    local st stc
    case "$STATE" in
        building) st="◐  building …"; stc="$C_YEL" ;;
        ok)       st="✔  success";    stc="$C_GRN" ;;
        failed)   st="✖  failed";     stc="$C_RED" ;;
        *)        st="·  idle";       stc="$C_DIM" ;;
    esac

    printf '%s\n' "${C_CYN}════════════════════════════════════════════════════════════════════════${C_RESET}"
    printf ' %sDESY · Metadata Schema report%s\n' "$C_BOLD" "$C_RESET"
    printf ' %sAli Farzanehpoor Alwars · a.farzaneh@desy.de%s\n' "$C_DIM" "$C_RESET"
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
    printf ' %-11s %s\n' "remotes"    \
      "ok:[${PUSH_OK[*]:-—}]  fail:[${PUSH_FAIL[*]:-—}]  throttle:${PUSH_MIN_INTERVAL}s"
    printf ' %-11s %s\n' "session"    \
      "${SESSION_BUILDS} builds · ${SESSION_OK} ok · ${SESSION_FAIL} failed"
    printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────────────────${C_RESET}"
    printf ' %s⟳  waiting for the next save …        Ctrl-C to stop%s\n' "$C_DIM" "$C_RESET"
    printf '%s\n' "${C_CYN}════════════════════════════════════════════════════════════════════════${C_RESET}"
}

draw() { printf '\033[H\033[J'; build_frame; }

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
        "$(date -Is)" "$REV" "$BUILD_NO" "$STATE" "$DUR_S" \
        "$PDF_PAGES" "$bytes" "${sha:-na}" "$LAST_BACKUP" >> "$VERSIONS_TSV"
}

# -------------------------------- SNAPSHOTS ----------------------------------
make_backup() {
    (( BACKUP_ENABLE )) || return 0
    mkdir -p "$BACKUP_ROOT"
    local dest="${BACKUP_ROOT}/v${REV}_$(date +%Y-%m-%d_%H-%M-%S)_$(basename "$PROJECT_DIR").zip"
    if ( cd "$PROJECT_DIR" && zip -r -9 -q "$dest" . \
            -x 'build/*' '.git/*' '.build-logs/*' '*.aux' '*.log' '*.out' \
               '*.toc' '*.synctex.gz' '*.fls' '*.fdb_latexmk' '*.bbl' '*.blg' ); then
        LAST_BACKUP="$(basename "$dest")"
    else
        LAST_BACKUP="backup failed"
        log_session "backup FAILED -> $dest"
    fi
    ls -1t "${BACKUP_ROOT}"/*.zip 2>/dev/null \
        | tail -n +$(( KEEP_BACKUPS + 1 )) | xargs -r rm -f
}

# ---------------------------------- GIT / SNS --------------------------------
_push_remote() {
    local name="$1" url="$2"
    ( cd "$PROJECT_DIR" || exit 1
      if git remote get-url "$name" >/dev/null 2>&1
         then git remote set-url "$name" "$url"
         else git remote add    "$name" "$url"; fi
      timeout 180 git push -q "$name" "HEAD:${GIT_BRANCH}" )
}

sns_sync() {
    (( SNS_ENABLE )) || return 0
    command -v rclone >/dev/null 2>&1 || { PUSH_FAIL+=("sns:rclone"); return 0; }

    local rc=0
    if [[ "$SNS_MODE" == "mirror" ]]; then
        rclone sync "$PROJECT_DIR" "${SNS_REMOTE}:${SNS_PATH}" \
            --exclude 'build/**' --exclude '.git/**' --exclude '.build-logs/**' \
            --create-empty-src-dirs --quiet --timeout 120 || rc=$?
    else
        [[ "$LAST_BACKUP" == *.zip ]] || return 0
        rclone copy "${BACKUP_ROOT}/${LAST_BACKUP}" \
            "${SNS_REMOTE}:${SNS_PATH}/snapshots" --quiet --timeout 120 || rc=$?
    fi
    (( rc == 0 )) && PUSH_OK+=("sns") || PUSH_FAIL+=("sns")
}

git_sync() {
    (( GIT_ENABLE )) || return 0
    command -v git >/dev/null 2>&1 || { PUSH_FAIL+=("git:missing"); return 0; }
    ( cd "$PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1 ) \
        || { PUSH_FAIL+=("not-a-repo"); return 0; }

    ( cd "$PROJECT_DIR" || exit 1
      git add -A
      git diff --cached --quiet && exit 0
      git commit -q -m "build v${REV}: ${STATE} · $(date '+%Y-%m-%d %H:%M:%S')"
    ) || { PUSH_FAIL+=("commit"); return 0; }

    (( GIT_PUSH )) || return 0

    local now; now=$(date +%s)
    (( now - LAST_PUSH_EPOCH < PUSH_MIN_INTERVAL )) && return 0
    LAST_PUSH_EPOCH=$now

    PUSH_OK=(); PUSH_FAIL=()

    if (( GITLAB_ENABLE )); then
        _push_remote "$GITLAB_REMOTE" "$GITLAB_URL" \
            && PUSH_OK+=("gitlab") || PUSH_FAIL+=("gitlab")
    fi
    if (( GITHUB_ENABLE )); then
        _push_remote "$GITHUB_REMOTE" "$GITHUB_URL" \
            && PUSH_OK+=("github") || PUSH_FAIL+=("github")
    fi
    sns_sync
    log_session "push: ok=[${PUSH_OK[*]:-}] fail=[${PUSH_FAIL[*]:-}]"
}

# ---------------------------------- BUILD ------------------------------------
run_build() {
    local reason="${1:-manual}"
    BUILD_NO=$(( BUILD_NO + 1 ))
    REV=$(( REV + 1 ))
    STATE="building"
    LAST_START="$(date '+%H:%M:%S')"
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

    LAST_END="$(date '+%H:%M:%S')"
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

    local pdf="${BUILD_DIR}/${MAIN_TEX%.tex}.pdf"
    if [[ -f "$pdf" ]]; then
        PDF_PAGES="$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/{print $2}')"
        PDF_PAGES="${PDF_PAGES:-?}"
        PDF_SIZE="$(human_size "$(stat -c%s "$pdf")")"
    else
        PDF_PAGES="—"; PDF_SIZE="no pdf"
    fi

    [[ "$STATE" == "ok" ]] && make_backup
    record_version
    git_sync
    log_session "build=${BUILD_NO} rev=v${REV} state=${STATE} dur=${DUR_S}s reason=${reason}"
    draw
}

# --------------------------------- WATCHER -----------------------------------
watch_loop() {
    local fname
    while IFS= read -r fname; do
        [[ "$fname" =~ $WATCH_REGEX ]] || continue
        LAST_FILE="$fname"
        while IFS= read -r -t "$DEBOUNCE" _; do :; done
        LAST_SAVE="$(date '+%H:%M:%S')"
        run_build "save: ${fname}"
    done < <(inotifywait -m -q -e close_write,moved_to --format '%f' "$PROJECT_DIR" 2>/dev/null)
}

# --------------------------------- CLEANUP -----------------------------------
cleanup() {
    trap - EXIT INT TERM
    printf '\033[?25h\033[0m'
    log_session "session end: ${SESSION_BUILDS} builds, ${SESSION_OK} ok, ${SESSION_FAIL} failed"
    printf '\n %sSession:%s %d builds · %d ok · %d failed\n' \
           "$C_BOLD" "$C_RESET" "$SESSION_BUILDS" "$SESSION_OK" "$SESSION_FAIL"
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
    trap cleanup EXIT INT TERM

    printf '\033[2J\033[?25l'
    log_session "session start (cores=${CORES}, project=${PROJECT_DIR})"

    draw
    (( OPT_NO_BUILD )) || run_build "startup"
    watch_loop
}

main "$@"
