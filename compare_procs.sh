#!/usr/bin/env bash
##############################################################################
# compare_procs.sh
#
# Compares stored procedures between a Git repository and a live Sybase ASE
# (SAP ASE) production database, word-by-word, and produces an HTML
# dashboard with five scenarios:
#
#   1. MATCH        - proc exists in both Git and PROD and content is identical
#   2. GIT_ONLY      - proc exists in Git but not in PROD
#   3. PROD_ONLY      - proc exists in PROD but not in Git
#   4. DIFF        - proc exists in both but content differs (word-level diff shown)
#   5. DATE_GAP      - Git last-commit date vs PROD created date, gap in days
#
# ---------------------------------------------------------------------------
# REQUIREMENTS
#   - bash 4+ (associative arrays)
#   - git            (to read commit dates / clone the repo)
#   - isql           (Sybase/SAP ASE command line client) reachable on PATH
#   - standard unix tools: awk, sed, diff, md5sum, date
#
# SETUP
#   1. Copy db.conf.example -> db.conf, fill in your Sybase connection
#      details (user, password, server). These stay in the config file
#      on purpose - never pass credentials as command line arguments.
#   2. chmod +x compare_procs.sh
#
# USAGE
#   ./compare_procs.sh <DATABASE_NAME> <GIT_REPO> [GIT_BRANCH]
#
#   <DATABASE_NAME>  Sybase ASE database to pull stored procedures from
#                    (overrides SYBASE_DB in db.conf if that is also set)
#
#   <GIT_REPO>      Either:
#                      - a local path to an already-cloned repo, e.g.
#                        /home/user/repos/myapp
#                      - a remote URL, e.g.
#                        https://github.com/org/myapp.git
#                        git@github.com:org/myapp.git
#                    Remote URLs are cloned fresh into a temp folder.
#                    Local paths are used as-is (run your own `git pull`
#                    beforehand if you want the latest commits).
#
#   [GIT_BRANCH]    Optional branch/tag to check out. Defaults to the
#                    repo's default branch.
#
# EXAMPLES
#   ./compare_procs.sh SalesDB /home/user/repos/sales-app
#   ./compare_procs.sh SalesDB https://github.com/org/sales-app.git main
#
# The script assumes ONE stored procedure per .sql file in Git, with the
# filename (minus extension) equal to the procedure name, e.g.
#   stored_procedures/usp_get_customer.sql   ->  proc "usp_get_customer"
# The sub-folder to scan (GIT_PROC_SUBDIR) and file extension (GIT_PROC_EXT)
# are set in db.conf.
##############################################################################

set -uo pipefail

usage() {
  echo "Usage: $0 <DATABASE_NAME> <GIT_REPO_URL_OR_PATH> [GIT_BRANCH]"
  echo
  echo "  DATABASE_NAME         Sybase ASE database to compare"
  echo "  GIT_REPO_URL_OR_PATH  Local repo path OR a remote git URL to clone"
  echo "  GIT_BRANCH            Optional branch/tag (default: repo default branch)"
  echo
  echo "Example:"
  echo "  $0 SalesDB /home/user/repos/sales-app"
  echo "  $0 SalesDB https://github.com/org/sales-app.git main"
  exit 1
}

[[ $# -lt 2 ]] && usage

ARG_DATABASE_NAME="$1"
ARG_GIT_REPO="$2"
ARG_GIT_BRANCH="${3:-}"

# ---------------------------------------------------------------------------
# 0. Load configuration (credentials + scan settings only)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/db.conf"

if [[ ! -f "${CONF_FILE}" ]]; then
  echo "ERROR: ${CONF_FILE} not found."
  echo "       Copy db.conf.example to db.conf and fill in your settings first."
  exit 1
fi
# shellcheck source=/dev/null
source "${CONF_FILE}"

: "${SYBASE_USER:?SYBASE_USER not set in db.conf}"
: "${SYBASE_PASS:?SYBASE_PASS not set in db.conf}"
: "${SYBASE_SERVER:?SYBASE_SERVER not set in db.conf}"
: "${GIT_PROC_SUBDIR:=.}"
: "${GIT_PROC_EXT:=sql}"
: "${ISQL_BIN:=isql}"
: "${OUTPUT_DIR:=./output}"
: "${OUTPUT_HTML:=dashboard.html}"

# CLI arguments take priority over db.conf
SYBASE_DB="${ARG_DATABASE_NAME}"

mkdir -p "${OUTPUT_DIR}"
RUN_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------------------
# 1. Prerequisite checks
# ---------------------------------------------------------------------------
for cmd in git diff md5sum awk sed date "${ISQL_BIN}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' not found on PATH."
    exit 1
  fi
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/prod_raw" "${WORKDIR}/prod_norm" "${WORKDIR}/git_norm" "${WORKDIR}/diffs"

# ---------------------------------------------------------------------------
# 1b. Resolve the Git repo: clone if it's a URL, use as-is if it's a path
# ---------------------------------------------------------------------------
is_git_url() {
  [[ "$1" =~ ^(https?|git|ssh|file)://.*$ ]] && return 0
  [[ "$1" =~ ^[A-Za-z0-9._-]+@.*:.*$ ]] && return 0   # git@host:org/repo.git style
  [[ "$1" == *.git ]] && return 0
  return 1
}

if is_git_url "${ARG_GIT_REPO}"; then
  echo "[0/6] Cloning Git repo ${ARG_GIT_REPO} ..."
  CLONE_DIR="${WORKDIR}/repo_clone"
  if [[ -n "${ARG_GIT_BRANCH}" ]]; then
    if ! git clone --quiet --branch "${ARG_GIT_BRANCH}" "${ARG_GIT_REPO}" "${CLONE_DIR}" 2>"${WORKDIR}/clone.err"; then
      echo "ERROR: git clone failed:"; cat "${WORKDIR}/clone.err"; exit 1
    fi
  else
    if ! git clone --quiet "${ARG_GIT_REPO}" "${CLONE_DIR}" 2>"${WORKDIR}/clone.err"; then
      echo "ERROR: git clone failed:"; cat "${WORKDIR}/clone.err"; exit 1
    fi
  fi
  GIT_REPO_PATH="${CLONE_DIR}"
else
  GIT_REPO_PATH="${ARG_GIT_REPO%/}"
  if [[ ! -d "${GIT_REPO_PATH}/.git" ]]; then
    echo "ERROR: ${GIT_REPO_PATH} is not a git repository (no .git folder found)."
    exit 1
  fi
  if [[ -n "${ARG_GIT_BRANCH}" ]]; then
    echo "[0/6] Checking out branch '${ARG_GIT_BRANCH}' in ${GIT_REPO_PATH} ..."
    if ! (cd "${GIT_REPO_PATH}" && git checkout --quiet "${ARG_GIT_BRANCH}"); then
      echo "ERROR: could not checkout branch '${ARG_GIT_BRANCH}' in ${GIT_REPO_PATH}."
      exit 1
    fi
  fi
fi

echo "[1/6] Work directory: ${WORKDIR}"
echo "       Database : ${SYBASE_DB}"
echo "       Git repo : ${GIT_REPO_PATH}"

# ---------------------------------------------------------------------------
# 2. Normalization helper
#    Strips block/line comments and collapses whitespace/case so that the
#    comparison is a true "word by word" content comparison and is not
#    thrown off by formatting, comment, or whitespace differences.
# ---------------------------------------------------------------------------
normalize_file() {
  # $1 = input file, $2 = output file
  sed -e 's#/\*.*\*/##g' "$1" \
    | sed -e 's/--.*$//' \
    | tr -s '[:space:]' ' ' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/^ *//' -e 's/ *$//' \
    > "$2"
}

word_split_file() {
  # $1 = normalized (single line) file, $2 = output file, one word per line
  tr ' ' '\n' < "$1" | sed '/^$/d' > "$2"
}

# ---------------------------------------------------------------------------
# 3. Extract stored procedures from PROD (Sybase ASE)
# ---------------------------------------------------------------------------
echo "[2/6] Querying PROD for stored procedure list..."

PROD_LIST="${WORKDIR}/prod_list.txt"

"${ISQL_BIN}" -U "${SYBASE_USER}" -P "${SYBASE_PASS}" -S "${SYBASE_SERVER}" -D "${SYBASE_DB}" -b -w 999 <<-EOSQL > "${PROD_LIST}" 2>"${WORKDIR}/prod_list.err"
set nocount on
go
select convert(varchar(255), o.name) + '|' + convert(varchar(20), o.crdate, 23)
from sysobjects o
where o.type = 'P'
order by o.name
go
EOSQL

if [[ ! -s "${PROD_LIST}" ]]; then
  echo "ERROR: could not retrieve proc list from PROD. isql said:"
  cat "${WORKDIR}/prod_list.err"
  exit 1
fi

# Clean isql banner/footer noise, keep only "name|date" lines
grep -E '^[A-Za-z0-9_#]+\|[0-9]{4}-[0-9]{2}-[0-9]{2}' "${PROD_LIST}" > "${WORKDIR}/prod_list.clean.txt" || true

PROD_COUNT=$(wc -l < "${WORKDIR}/prod_list.clean.txt" | tr -d ' ')
echo "       Found ${PROD_COUNT} procedures in PROD."

echo "[3/6] Extracting PROD procedure bodies (this may take a while for large counts)..."

declare -A PROD_DATE
declare -A PROD_HASH

while IFS='|' read -r PNAME PCRDATE; do
  [[ -z "${PNAME}" ]] && continue
  RAW_FILE="${WORKDIR}/prod_raw/${PNAME}.sql"

  "${ISQL_BIN}" -U "${SYBASE_USER}" -P "${SYBASE_PASS}" -S "${SYBASE_SERVER}" -D "${SYBASE_DB}" -b -w 999 <<-EOSQL > "${RAW_FILE}" 2>/dev/null
	set nocount on
	go
	select c.text
	from syscomments c, sysobjects o
	where o.id = c.id and o.name = '${PNAME}'
	order by c.colid
	go
	EOSQL

  NORM_FILE="${WORKDIR}/prod_norm/${PNAME}.txt"
  normalize_file "${RAW_FILE}" "${NORM_FILE}"

  PROD_DATE["${PNAME}"]="${PCRDATE}"
  PROD_HASH["${PNAME}"]="$(md5sum "${NORM_FILE}" | awk '{print $1}')"
done < "${WORKDIR}/prod_list.clean.txt"

# ---------------------------------------------------------------------------
# 4. Extract stored procedures from Git
# ---------------------------------------------------------------------------
echo "[4/6] Extracting stored procedures from Git repo..."

GIT_PROC_DIR="${GIT_REPO_PATH%/}/${GIT_PROC_SUBDIR}"
if [[ ! -d "${GIT_PROC_DIR}" ]]; then
  echo "ERROR: ${GIT_PROC_DIR} does not exist."
  exit 1
fi

declare -A GIT_DATE
declare -A GIT_HASH

while IFS= read -r -d '' FILE; do
  PNAME="$(basename "${FILE}" ".${GIT_PROC_EXT}")"
  NORM_FILE="${WORKDIR}/git_norm/${PNAME}.txt"
  normalize_file "${FILE}" "${NORM_FILE}"

  # last commit date that touched this file
  COMMIT_DATE="$(cd "${GIT_REPO_PATH}" && git log -1 --date=short --format=%ad -- "${GIT_PROC_SUBDIR}/$(basename "${FILE}")" 2>/dev/null)"
  if [[ -z "${COMMIT_DATE}" ]]; then
    COMMIT_DATE="$(date -r "${FILE}" '+%Y-%m-%d' 2>/dev/null || echo "unknown")"
  fi

  GIT_DATE["${PNAME}"]="${COMMIT_DATE}"
  GIT_HASH["${PNAME}"]="$(md5sum "${NORM_FILE}" | awk '{print $1}')"
done < <(find "${GIT_PROC_DIR}" -type f -name "*.${GIT_PROC_EXT}" -print0)

GIT_COUNT=${#GIT_HASH[@]}
echo "       Found ${GIT_COUNT} procedures in Git."

# ---------------------------------------------------------------------------
# 5. Build the five scenarios
# ---------------------------------------------------------------------------
echo "[5/6] Comparing and building scenarios..."

MATCH_ROWS=""
GITONLY_ROWS=""
PRODONLY_ROWS=""
DIFF_ROWS=""
DATE_ROWS=""

MATCH_N=0; GITONLY_N=0; PRODONLY_N=0; DIFF_N=0

# union of all proc names
ALL_NAMES="$(printf '%s\n' "${!GIT_HASH[@]}" "${!PROD_HASH[@]}" | sort -u)"

days_between() {
  # $1, $2 = YYYY-MM-DD dates -> absolute day difference
  local d1 d2
  d1=$(date -d "$1" +%s 2>/dev/null) || { echo "n/a"; return; }
  d2=$(date -d "$2" +%s 2>/dev/null) || { echo "n/a"; return; }
  echo $(( (d2 - d1) / 86400 ))
}

for NAME in ${ALL_NAMES}; do
  IN_GIT=0; IN_PROD=0
  [[ -n "${GIT_HASH[${NAME}]+x}" ]] && IN_GIT=1
  [[ -n "${PROD_HASH[${NAME}]+x}" ]] && IN_PROD=1

  if [[ ${IN_GIT} -eq 1 && ${IN_PROD} -eq 0 ]]; then
    GITONLY_N=$((GITONLY_N+1))
    GITONLY_ROWS+="<tr><td>${NAME}</td><td>${GIT_DATE[${NAME}]}</td></tr>"
    continue
  fi

  if [[ ${IN_GIT} -eq 0 && ${IN_PROD} -eq 1 ]]; then
    PRODONLY_N=$((PRODONLY_N+1))
    PRODONLY_ROWS+="<tr><td>${NAME}</td><td>${PROD_DATE[${NAME}]}</td></tr>"
    continue
  fi

  # present in both
  GDATE="${GIT_DATE[${NAME}]}"
  PDATE="${PROD_DATE[${NAME}]}"
  GAP="$(days_between "${GDATE}" "${PDATE}")"

  if [[ "${GIT_HASH[${NAME}]}" == "${PROD_HASH[${NAME}]}" ]]; then
    MATCH_N=$((MATCH_N+1))
    MATCH_ROWS+="<tr><td>${NAME}</td><td>${GDATE}</td><td>${PDATE}</td><td>${GAP}</td></tr>"
  else
    DIFF_N=$((DIFF_N+1))
    GIT_WORDS="${WORKDIR}/diffs/${NAME}.git.words"
    PROD_WORDS="${WORKDIR}/diffs/${NAME}.prod.words"
    word_split_file "${WORKDIR}/git_norm/${NAME}.txt" "${GIT_WORDS}"
    word_split_file "${WORKDIR}/prod_norm/${NAME}.txt" "${PROD_WORDS}"

    # Classify diff lines FIRST (while real < / > markers are intact),
    # then HTML-escape the extracted content, then wrap in spans.
    DIFF_HTML="$(diff "${GIT_WORDS}" "${PROD_WORDS}" \
      | awk '
          /^</ { print "RM:" substr($0,3); next }
          /^>/ { print "ADD:" substr($0,3); next }
          { next }
        ' \
      | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
      | sed -e 's/^RM:/<span class="rm">- /' -e 's/^ADD:/<span class="add">+ /' \
      | sed -e 's/$/<\/span><br>/')"

    DIFF_ROWS+="<tr class=\"diffrow\" onclick=\"toggleDiff('${NAME}')\">
      <td>${NAME} <span class=\"expand-hint\">(click to view word diff)</span></td>
      <td>${GDATE}</td><td>${PDATE}</td><td>${GAP}</td></tr>
      <tr id=\"diff-${NAME}\" class=\"diffdetail\" style=\"display:none\">
      <td colspan=\"4\"><div class=\"diffbox\">${DIFF_HTML}</div></td></tr>"
  fi

  DATE_ROWS+="<tr><td>${NAME}</td><td>${GDATE}</td><td>${PDATE}</td><td class=\"$( [[ ${GAP} != n/a && ${GAP#-} -gt 30 ]] 2>/dev/null && echo gap-high || echo gap-ok )\">${GAP}</td></tr>"
done

TOTAL=$((MATCH_N + GITONLY_N + PRODONLY_N + DIFF_N))

echo "       MATCH=${MATCH_N}  GIT_ONLY=${GITONLY_N}  PROD_ONLY=${PRODONLY_N}  DIFF=${DIFF_N}"

# ---------------------------------------------------------------------------
# 6. Render HTML dashboard
# ---------------------------------------------------------------------------
echo "[6/6] Writing HTML dashboard..."

OUT_FILE="${OUTPUT_DIR%/}/${OUTPUT_HTML}"

# simple CSS bar-chart widths (percentage of total, min 2% so a bar is visible)
bar_pct() {
  local n=$1
  if [[ ${TOTAL} -eq 0 ]]; then echo 0; return; fi
  local p=$(( n * 100 / TOTAL ))
  [[ $p -lt 2 && $n -gt 0 ]] && p=2
  echo "${p}"
}

cat > "${OUT_FILE}" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Stored Procedure Comparison Dashboard - Git vs Production</title>
<style>
  :root{
    --bg:#0f1724; --panel:#ffffff; --ink:#1f2937; --muted:#6b7280;
    --match:#16a34a; --gitonly:#2563eb; --prodonly:#d97706; --diff:#dc2626; --dategap:#7c3aed;
    --line:#e5e7eb;
  }
  *{box-sizing:border-box;}
  body{
    margin:0; font-family:"Segoe UI",Helvetica,Arial,sans-serif;
    background:linear-gradient(180deg,#0f1724 0%,#1e293b 260px, #f3f4f6 260px);
    color:var(--ink);
  }
  .wrap{max-width:1200px;margin:0 auto;padding:24px;}
  header{padding:28px 0 10px 0;color:#fff;}
  header h1{margin:0;font-size:26px;font-weight:700;}
  header p{margin:6px 0 0 0;color:#cbd5e1;font-size:13px;}
  .cards{display:grid;grid-template-columns:repeat(5,1fr);gap:16px;margin:24px 0;}
  .card{
    background:var(--panel);border-radius:12px;padding:18px 16px;
    box-shadow:0 4px 14px rgba(0,0,0,.08); border-top:4px solid var(--muted);
  }
  .card h2{margin:0;font-size:30px;}
  .card p{margin:4px 0 0 0;color:var(--muted);font-size:12.5px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;}
  .card.match{border-top-color:var(--match);}
  .card.gitonly{border-top-color:var(--gitonly);}
  .card.prodonly{border-top-color:var(--prodonly);}
  .card.diff{border-top-color:var(--diff);}
  .card.dategap{border-top-color:var(--dategap);}
  .chart{background:var(--panel);border-radius:12px;padding:20px;box-shadow:0 4px 14px rgba(0,0,0,.08);margin-bottom:28px;}
  .chart h3{margin:0 0 14px 0;font-size:15px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;}
  .barrow{display:flex;align-items:center;margin:10px 0;font-size:13px;}
  .barlabel{width:150px;flex-shrink:0;color:var(--ink);font-weight:600;}
  .bartrack{flex:1;background:#f1f5f9;border-radius:6px;height:18px;overflow:hidden;margin-right:10px;}
  .barfill{height:100%;border-radius:6px;}
  .barval{width:40px;text-align:right;color:var(--muted);}
  section{background:var(--panel);border-radius:12px;padding:20px;margin-bottom:24px;box-shadow:0 4px 14px rgba(0,0,0,.08);}
  section h3{margin-top:0;font-size:16px;display:flex;align-items:center;gap:8px;}
  .badge{display:inline-block;font-size:12px;font-weight:700;color:#fff;padding:2px 9px;border-radius:999px;}
  .badge.match{background:var(--match);}
  .badge.gitonly{background:var(--gitonly);}
  .badge.prodonly{background:var(--prodonly);}
  .badge.diff{background:var(--diff);}
  .badge.dategap{background:var(--dategap);}
  table{width:100%;border-collapse:collapse;font-size:13.5px;}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);}
  th{color:var(--muted);text-transform:uppercase;font-size:11px;letter-spacing:.04em;}
  tr.diffrow{cursor:pointer;}
  tr.diffrow:hover{background:#fef2f2;}
  .expand-hint{color:var(--muted);font-size:11.5px;font-weight:400;}
  .diffbox{background:#0b1220;color:#e2e8f0;font-family:Consolas,monospace;font-size:12.5px;
    padding:14px;border-radius:8px;max-height:320px;overflow:auto;line-height:1.6;}
  .diffbox .rm{color:#fca5a5;}
  .diffbox .add{color:#86efac;}
  .diffbox .ctx{color:#94a3b8;}
  .gap-high{color:var(--diff);font-weight:700;}
  .gap-ok{color:var(--muted);}
  .empty{color:var(--muted);font-style:italic;padding:10px 0;}
  footer{color:var(--muted);font-size:12px;text-align:center;padding:20px 0 40px 0;}
  @media (max-width:900px){.cards{grid-template-columns:repeat(2,1fr);}}
</style>
<script>
  function toggleDiff(name){
    var row = document.getElementById('diff-' + name);
    if(!row) return;
    row.style.display = (row.style.display === 'none' || row.style.display === '') ? 'table-row' : 'none';
  }
</script>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Stored Procedure Comparison Dashboard</h1>
    <p>Git repository vs Sybase ASE (SAP ASE) Production &nbsp;|&nbsp; Generated ${RUN_DATE}</p>
    <p>Git procs scanned: ${GIT_COUNT} &nbsp;|&nbsp; PROD procs scanned: ${PROD_COUNT}</p>
  </header>

  <div class="cards">
    <div class="card match"><h2>${MATCH_N}</h2><p>Exact Match</p></div>
    <div class="card gitonly"><h2>${GITONLY_N}</h2><p>Git Only</p></div>
    <div class="card prodonly"><h2>${PRODONLY_N}</h2><p>PROD Only</p></div>
    <div class="card diff"><h2>${DIFF_N}</h2><p>Differences</p></div>
    <div class="card dategap"><h2>${TOTAL}</h2><p>Total Compared</p></div>
  </div>

  <div class="chart">
    <h3>Scenario Distribution</h3>
    <div class="barrow"><div class="barlabel">Match</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${MATCH_N})%;background:var(--match);"></div></div><div class="barval">${MATCH_N}</div></div>
    <div class="barrow"><div class="barlabel">Git Only</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${GITONLY_N})%;background:var(--gitonly);"></div></div><div class="barval">${GITONLY_N}</div></div>
    <div class="barrow"><div class="barlabel">PROD Only</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${PRODONLY_N})%;background:var(--prodonly);"></div></div><div class="barval">${PRODONLY_N}</div></div>
    <div class="barrow"><div class="barlabel">Differences</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${DIFF_N})%;background:var(--diff);"></div></div><div class="barval">${DIFF_N}</div></div>
  </div>

  <section>
    <h3><span class="badge match">1</span> Exact Matches (Git = PROD)</h3>
    <table>
      <tr><th>Procedure</th><th>Git Commit Date</th><th>PROD Created Date</th><th>Date Gap (days)</th></tr>
      ${MATCH_ROWS:-<tr><td class=\"empty\" colspan=\"4\">No exact matches found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge gitonly">2</span> Present in Git but Missing in PROD</h3>
    <table>
      <tr><th>Procedure</th><th>Git Commit Date</th></tr>
      ${GITONLY_ROWS:-<tr><td class=\"empty\" colspan=\"2\">None found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge prodonly">3</span> Present in PROD but Missing in Git</h3>
    <table>
      <tr><th>Procedure</th><th>PROD Created Date</th></tr>
      ${PRODONLY_ROWS:-<tr><td class=\"empty\" colspan=\"2\">None found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge diff">4</span> Differences Between Git and PROD</h3>
    <table>
      <tr><th>Procedure</th><th>Git Commit Date</th><th>PROD Created Date</th><th>Date Gap (days)</th></tr>
      ${DIFF_ROWS:-<tr><td class=\"empty\" colspan=\"4\">No content differences found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge dategap">5</span> Git Commit Date vs PROD Created Date (Days)</h3>
    <table>
      <tr><th>Procedure</th><th>Git Commit Date</th><th>PROD Created Date</th><th>Gap (days)</th></tr>
      ${DATE_ROWS:-<tr><td class=\"empty\" colspan=\"4\">No procedures present in both sources.</td></tr>}
    </table>
  </section>

  <footer>Comparison is word/content-based after stripping comments and whitespace differences. Word diffs above show removed (red, from Git) and added (green, from PROD) tokens.</footer>
</div>
</body>
</html>
HTMLEOF

echo "Done. Dashboard written to: ${OUT_FILE}"
