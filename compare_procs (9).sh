#!/usr/bin/env bash
##############################################################################
# compare_procs.sh
#
# Compares stored procedures between a local folder of .sql files (manually
# copied out of Git, or from anywhere) and a live Sybase ASE (SAP ASE)
# production database, word-by-word, and produces an HTML dashboard with
# four scenarios:
#
#   1. DIFF        - procedure exists in both but content differs (word-level diff shown)
#   2. PROD_ONLY    - procedure exists in PROD but is missing from the folder
#   3. FOLDER_ONLY  - procedure exists in the folder but is missing from PROD
#   4. MATCH        - procedure exists in both and content is identical
#
# There is NO Git dependency anywhere in this script - it only ever reads
# plain .sql files from a folder you point it at.
#
# ---------------------------------------------------------------------------
# REQUIREMENTS
#   - bash 4+ (associative arrays)
#   - isql           (Sybase/SAP ASE command line client) reachable on PATH
#   - standard unix tools: awk, sed, diff, md5sum
#
# SETUP
#   1. Copy db.conf.example -> db.conf, fill in your Sybase connection
#      details (user, password, server). These stay in the config file
#      on purpose - never pass credentials as command line arguments.
#   2. chmod +x compare_procs.sh
#
# USAGE
#   ./compare_procs.sh <DATABASE_NAME> <FOLDER_PATH>
#
#   <DATABASE_NAME>   Sybase ASE database to pull stored procedures from
#
#   <FOLDER_PATH>     Local folder containing the stored procedure .sql
#                     files (e.g. files you downloaded/copied from Git by
#                     hand). One procedure per file, filename (minus
#                     extension) = procedure name, e.g.
#                       usp_get_customer.sql -> proc "usp_get_customer"
#                     The folder is scanned recursively.
#
# EXAMPLE
#   ./compare_procs.sh SalesDB /home/user/sql_from_git
#
# The sub-folder to scan (PROC_SUBDIR, use "." for the folder itself) and
# file extension (PROC_EXT) are set in db.conf.
##############################################################################

set -uo pipefail

usage() {
  echo "Usage: $0 <DATABASE_NAME> <FOLDER_PATH>"
  echo
  echo "  DATABASE_NAME   Sybase ASE database to compare"
  echo "  FOLDER_PATH     Local folder containing the stored procedure .sql files"
  echo
  echo "Example:"
  echo "  $0 SalesDB /home/user/sql_from_git"
  exit 1
}

[[ $# -lt 2 ]] && usage

ARG_DATABASE_NAME="$1"
ARG_SRC_DIR="$2"

# ---------------------------------------------------------------------------
# 0. Load configuration
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
: "${PROC_SUBDIR:=.}"
: "${PROC_EXT:=sql}"
: "${ISQL_BIN:=isql}"
: "${OUTPUT_DIR:=./output}"
: "${OUTPUT_HTML:=}"

SYBASE_DB="${ARG_DATABASE_NAME}"

# Auto-name the report as <DATABASE>_<YYYYMMDD>_<HHMMSS>.html so running
# this against multiple databases never overwrites a previous result.
# Set OUTPUT_HTML in db.conf to a fixed name instead if you don't want this.
if [[ -z "${OUTPUT_HTML}" ]]; then
  SAFE_DB_NAME="$(printf '%s' "${SYBASE_DB}" | tr -c 'A-Za-z0-9_-' '_')"
  OUTPUT_HTML="${SAFE_DB_NAME}_$(date '+%Y%m%d_%H%M%S').html"
fi

mkdir -p "${OUTPUT_DIR}"
RUN_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------------------
# 1. Prerequisite checks
# ---------------------------------------------------------------------------
for cmd in diff md5sum awk sed "${ISQL_BIN}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' not found on PATH."
    exit 1
  fi
done

SRC_DIR="${ARG_SRC_DIR%/}"
if [[ ! -d "${SRC_DIR}" ]]; then
  echo "ERROR: ${SRC_DIR} is not a directory (or doesn't exist)."
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/prod_raw" "${WORKDIR}/prod_norm" "${WORKDIR}/src_norm" "${WORKDIR}/diffs"

echo "[1/5] Work directory: ${WORKDIR}"
echo "       Database    : ${SYBASE_DB}"
echo "       Source folder: ${SRC_DIR}"

# ---------------------------------------------------------------------------
# 2. Normalization helper
#    Strips block/line comments and collapses whitespace/case so the
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


# ---------------------------------------------------------------------------
# 3. Extract stored procedures from PROD (Sybase ASE)
# ---------------------------------------------------------------------------
echo "[2/5] Querying PROD for stored procedure list..."

PROD_LIST="${WORKDIR}/prod_list.txt"

"${ISQL_BIN}" -U "${SYBASE_USER}" -P "${SYBASE_PASS}" -S "${SYBASE_SERVER}" -D "${SYBASE_DB}" -b -w 999 <<-EOSQL > "${PROD_LIST}" 2>"${WORKDIR}/prod_list.err"
set nocount on
go
select convert(varchar(255), o.name)
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

# Clean isql banner/footer noise, keep only proc-name-looking lines.
# Be forgiving here: strip carriage returns and stray leading/trailing
# whitespace FIRST, then drop anything that clearly isn't a name (blank
# lines, dashed separators, "(N rows affected)" messages, etc). A strict
# "must match this exact pattern" filter is too brittle - different isql
# builds/configs add slightly different invisible whitespace/line-ending
# noise, and a stricter filter can silently drop real, valid proc names.
tr -d '\r' < "${PROD_LIST}" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' \
  | grep -v '^-\+$' \
  | grep -vi '^([0-9]\+ rows\? affected)$' \
  | grep -v '^>' \
  > "${WORKDIR}/prod_list.clean.txt" || true

PROD_COUNT=$(wc -l < "${WORKDIR}/prod_list.clean.txt" | tr -d ' ')
echo "       Found ${PROD_COUNT} procedures in PROD."

if [[ "${PROD_COUNT}" -eq 0 ]]; then
  echo
  echo "WARNING: 0 procedures found in PROD. This usually means the query"
  echo "         ran but returned no usable rows. Raw isql output was:"
  echo "         -------------------------------------------------------"
  sed 's/^/         /' "${PROD_LIST}"
  echo "         -------------------------------------------------------"
  if [[ -s "${WORKDIR}/prod_list.err" ]]; then
    echo "         isql stderr:"
    sed 's/^/         /' "${WORKDIR}/prod_list.err"
  fi
  echo
  echo "         Common causes: wrong database name, the login lacks SELECT"
  echo "         permission on sysobjects, or the database has genuinely no"
  echo "         stored procedures (type = 'P')."
  echo
fi

echo "[3/5] Extracting PROD procedure bodies (this may take a while for large counts)..."

declare -A PROD_HASH

while IFS= read -r PNAME; do
  [[ -z "${PNAME}" ]] && continue
  RAW_FILE="${WORKDIR}/prod_raw/${PNAME}.sql"

  # NOTE: We deliberately avoid querying syscomments.text directly.
  # syscomments stores a proc's body split across multiple rows in
  # fixed-length chunks that do NOT respect word boundaries, so a chunk
  # cut can land mid-word (e.g. "#ADF_" / "QUERIES" on two separate output
  # lines), causing false diffs. A text-reconstructing proc that respects
  # real source line boundaries avoids this. This environment uses
  # sp_showtext for that (confirmed working via manual test) rather than
  # the standard sp_helptext.
  #
  # stderr is captured per-proc instead of discarded, so if this proc
  # doesn't exist / errors out, we can tell instead of silently comparing
  # against an empty file (which would falsely show as DIFF against Git).
  "${ISQL_BIN}" -U "${SYBASE_USER}" -P "${SYBASE_PASS}" -S "${SYBASE_SERVER}" -D "${SYBASE_DB}" -b -w 999 <<-EOSQL > "${RAW_FILE}" 2>"${WORKDIR}/prod_raw/${PNAME}.err"
	set nocount on
	go
	sp_showtext ${PNAME}
	go
	EOSQL

  # A stored-proc EXEC causes isql to append a trailing
  # "(return status = N)" line, which is never part of the actual proc
  # source (Git never contains it) - strip it before hashing.
  grep -v -iE '^\(return status = -?[0-9]+\)$' "${RAW_FILE}" > "${RAW_FILE}.clean" \
    && mv "${RAW_FILE}.clean" "${RAW_FILE}"

  NORM_FILE="${WORKDIR}/prod_norm/${PNAME}.txt"
  normalize_file "${RAW_FILE}" "${NORM_FILE}"

  PROD_HASH["${PNAME}"]="$(md5sum "${NORM_FILE}" | awk '{print $1}')"

  [[ ! -s "${RAW_FILE}" ]] && EMPTY_PROD_EXTRACTS=$((${EMPTY_PROD_EXTRACTS:-0}+1))
done < "${WORKDIR}/prod_list.clean.txt"

if [[ "${EMPTY_PROD_EXTRACTS:-0}" -gt 0 ]]; then
  echo
  echo "WARNING: ${EMPTY_PROD_EXTRACTS} of ${PROD_COUNT} PROD procedures came back"
  echo "         with EMPTY extracted text. These will show as false DIFFs against"
  echo "         Git rather than real content differences. Sample error from the"
  echo "         first failing extraction:"
  echo "         -------------------------------------------------------"
  find "${WORKDIR}/prod_raw" -name '*.err' -size +0c -print -quit | xargs -r sed 's/^/         /'
  echo "         -------------------------------------------------------"
  echo
fi

# ---------------------------------------------------------------------------
# 4. Extract stored procedures from the local folder
# ---------------------------------------------------------------------------
echo "[4/5] Extracting stored procedures from local folder..."

SCAN_DIR="${SRC_DIR%/}/${PROC_SUBDIR}"
if [[ ! -d "${SCAN_DIR}" ]]; then
  echo "ERROR: ${SCAN_DIR} does not exist."
  exit 1
fi

declare -A SRC_HASH
declare -A SRC_RAWFILE

while IFS= read -r -d '' FILE; do
  # Strip the extension case-insensitively (handles usp_foo.sql, usp_foo.SQL, usp_foo.Sql, etc.)
  PNAME="$(basename "${FILE}" | sed -E "s/\.${PROC_EXT}\$//I")"
  NORM_FILE="${WORKDIR}/src_norm/${PNAME}.txt"
  normalize_file "${FILE}" "${NORM_FILE}"
  SRC_HASH["${PNAME}"]="$(md5sum "${NORM_FILE}" | awk '{print $1}')"
  SRC_RAWFILE["${PNAME}"]="${FILE}"
done < <(find "${SCAN_DIR}" -type f -iname "*.${PROC_EXT}" -print0)

set +u
SRC_COUNT=${#SRC_HASH[@]}
set -u
echo "       Found ${SRC_COUNT} procedures in the local folder."

if [[ "${SRC_COUNT}" -eq 0 ]]; then
  TOTAL_FILES_IN_DIR=$(find "${SCAN_DIR}" -type f | wc -l | tr -d ' ')
  echo
  echo "WARNING: 0 procedures found in ${SCAN_DIR}"
  echo "         Total files of any kind in that folder (recursive): ${TOTAL_FILES_IN_DIR}"
  if [[ "${TOTAL_FILES_IN_DIR}" -gt 0 ]]; then
    echo "         Sample of actual filenames found there:"
    find "${SCAN_DIR}" -type f | head -10 | sed 's/^/           /'
    echo
    echo "         The script is looking for files matching: *.${PROC_EXT} (case-insensitive)"
    echo "         Compare that against the sample above - if the real extension is"
    echo "         different (e.g. .prc, .txt, .storedproc), set PROC_EXT in db.conf"
    echo "         to match, without the leading dot."
  else
    echo "         The folder itself appears to be empty, or PROC_SUBDIR in db.conf"
    echo "         is pointing at the wrong place. PROC_SUBDIR is currently: '${PROC_SUBDIR}'"
    echo "         Full path being scanned: ${SCAN_DIR}"
  fi
  echo
fi

# ---------------------------------------------------------------------------
# 5. Build the four scenarios
# ---------------------------------------------------------------------------
echo "[5/5] Comparing and building scenarios..."

DIFF_ROWS=""
PRODONLY_ROWS=""
FOLDERONLY_ROWS=""
MATCH_ROWS=""

DIFF_N=0; PRODONLY_N=0; FOLDERONLY_N=0; MATCH_N=0

set +u
ALL_NAMES="$(printf '%s\n' "${!SRC_HASH[@]}" "${!PROD_HASH[@]}" | sort -u)"
set -u

for NAME in ${ALL_NAMES}; do
  IN_SRC=0; IN_PROD=0
  [[ -n "${SRC_HASH[${NAME}]+x}" ]] && IN_SRC=1
  [[ -n "${PROD_HASH[${NAME}]+x}" ]] && IN_PROD=1

  if [[ ${IN_SRC} -eq 1 && ${IN_PROD} -eq 0 ]]; then
    FOLDERONLY_N=$((FOLDERONLY_N+1))
    FOLDERONLY_ROWS+="<tr><td>${NAME}</td></tr>"
    continue
  fi

  if [[ ${IN_SRC} -eq 0 && ${IN_PROD} -eq 1 ]]; then
    PRODONLY_N=$((PRODONLY_N+1))
    PRODONLY_ROWS+="<tr><td>${NAME}</td></tr>"
    continue
  fi

  # present in both
  if [[ "${SRC_HASH[${NAME}]}" == "${PROD_HASH[${NAME}]}" ]]; then
    MATCH_N=$((MATCH_N+1))
    MATCH_ROWS+="<tr><td>${NAME}</td></tr>"
  else
    DIFF_N=$((DIFF_N+1))

    # Build a full side-by-side view: original Git/source content on the
    # left, original PROD content on the right, aligned line by line.
    # Only the lines that actually differ get highlighted - everything
    # else (the bulk of the procedure) shows normally so the user can
    # read the whole thing in context and spot exactly what changed.
    SRC_RAW="${SRC_RAWFILE[${NAME}]}"
    PROD_RAW="${WORKDIR}/prod_raw/${NAME}.sql"
    SRC_CLEAN="${WORKDIR}/diffs/${NAME}.src.clean"
    PROD_CLEAN="${WORKDIR}/diffs/${NAME}.prod.clean"
    # Strip stray \r so line endings never cause a false "difference"
    tr -d '\r' < "${SRC_RAW}" > "${SRC_CLEAN}"
    tr -d '\r' < "${PROD_RAW}" > "${PROD_CLEAN}"

    SBS_WIDTH=220
    MARKER_POS=$(( SBS_WIDTH / 2 ))

    DIFF_HTML="$(diff -y -t -W "${SBS_WIDTH}" "${SRC_CLEAN}" "${PROD_CLEAN}" \
      | awk -v mp="${MARKER_POS}" '
          {
            left  = substr($0, 1, mp-1)
            marker = substr($0, mp, 1)
            right = substr($0, mp+3)
            gsub(/[ \t]+$/, "", left)
            gsub(/&/, "\\&amp;", left);  gsub(/</, "\\&lt;", left);  gsub(/>/, "\\&gt;", left)
            gsub(/&/, "\\&amp;", right); gsub(/</, "\\&lt;", right); gsub(/>/, "\\&gt;", right)
            cls = (marker == " " || marker == "") ? "sbs-same" : "sbs-chg"
            print "<tr class=\"" cls "\"><td>" left "</td><td>" right "</td></tr>"
          }
        ')"

    DIFF_ROWS+="<tr class=\"diffrow\" onclick=\"toggleDiff('${NAME}')\">
      <td>${NAME} <span class=\"expand-hint\">(click to view side-by-side diff)</span></td></tr>
      <tr id=\"diff-${NAME}\" class=\"diffdetail\" style=\"display:none\">
      <td><div class=\"diffbox\"><table class=\"sbsdiff\">
        <tr class=\"sbs-hdr\"><th>Git</th><th>PROD</th></tr>
        ${DIFF_HTML}
      </table></div></td></tr>"
  fi
done

TOTAL=$((MATCH_N + FOLDERONLY_N + PRODONLY_N + DIFF_N))

echo "       DIFF=${DIFF_N}  PROD_ONLY=${PRODONLY_N}  FOLDER_ONLY=${FOLDERONLY_N}  MATCH=${MATCH_N}"

# ---------------------------------------------------------------------------
# 6. Render HTML dashboard
# ---------------------------------------------------------------------------
echo "Writing HTML dashboard..."

OUT_FILE="${OUTPUT_DIR%/}/${OUTPUT_HTML}"

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
    --match:#16a34a; --folderonly:#2563eb; --prodonly:#d97706; --diff:#dc2626;
    --line:#e5e7eb;
  }
  *{box-sizing:border-box;}
  body{
    margin:0; font-family:"Segoe UI",Helvetica,Arial,sans-serif;
    background:linear-gradient(180deg,#0f1724 0%,#1e293b 220px, #f3f4f6 220px);
    color:var(--ink);
  }
  .wrap{max-width:1100px;margin:0 auto;padding:24px;}
  header{padding:28px 0 10px 0;color:#fff;}
  header h1{margin:0;font-size:26px;font-weight:700;}
  header p{margin:6px 0 0 0;color:#cbd5e1;font-size:13px;}
  .cards{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:24px 0;}
  .card{
    background:var(--panel);border-radius:12px;padding:18px 16px;
    box-shadow:0 4px 14px rgba(0,0,0,.08); border-top:4px solid var(--muted);
  }
  .card h2{margin:0;font-size:30px;}
  .card p{margin:4px 0 0 0;color:var(--muted);font-size:12.5px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;}
  .card.diff{border-top-color:var(--diff);}
  .card.prodonly{border-top-color:var(--prodonly);}
  .card.folderonly{border-top-color:var(--folderonly);}
  .card.match{border-top-color:var(--match);}
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
  .badge.diff{background:var(--diff);}
  .badge.prodonly{background:var(--prodonly);}
  .badge.folderonly{background:var(--folderonly);}
  .badge.match{background:var(--match);}
  table{width:100%;border-collapse:collapse;font-size:13.5px;}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);}
  th{color:var(--muted);text-transform:uppercase;font-size:11px;letter-spacing:.04em;}
  tr.diffrow{cursor:pointer;}
  tr.diffrow:hover{background:#fef2f2;}
  .expand-hint{color:var(--muted);font-size:11.5px;font-weight:400;}
  .diffbox{background:#0b1220;color:#e2e8f0;font-family:Consolas,monospace;font-size:12px;
    padding:0;border-radius:8px;max-height:420px;overflow:auto;line-height:1.5;}
  table.sbsdiff{width:100%;border-collapse:collapse;font-size:12px;}
  table.sbsdiff td, table.sbsdiff th{
    width:50%;padding:3px 10px;white-space:pre;overflow-x:auto;
    border-bottom:1px solid #1e293b;vertical-align:top;
  }
  table.sbsdiff th{
    position:sticky;top:0;background:#0f1724;color:#93c5fd;text-align:left;
    text-transform:uppercase;font-size:11px;letter-spacing:.05em;padding:8px 10px;
    border-bottom:1px solid #334155;
  }
  table.sbsdiff td:first-child{border-right:1px solid #1e293b;}
  tr.sbs-same td{color:#94a3b8;}
  tr.sbs-chg td{background:#3b0d0d;color:#fecaca;}
  tr.sbs-chg td:last-child{background:#0d2e17;color:#bbf7d0;}
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
    <p>Git vs Sybase ASE (SAP ASE) Production &nbsp;|&nbsp; Generated ${RUN_DATE}</p>
    <p>Git procs scanned: ${SRC_COUNT} &nbsp;|&nbsp; PROD procs scanned: ${PROD_COUNT}</p>
  </header>

  <div class="cards">
    <div class="card diff"><h2>${DIFF_N}</h2><p>Differences</p></div>
    <div class="card prodonly"><h2>${PRODONLY_N}</h2><p>PROD Only</p></div>
    <div class="card folderonly"><h2>${FOLDERONLY_N}</h2><p>Git Only</p></div>
    <div class="card match"><h2>${MATCH_N}</h2><p>Identical</p></div>
  </div>

  <div class="chart">
    <h3>Scenario Distribution</h3>
    <div class="barrow"><div class="barlabel">Differences</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${DIFF_N})%;background:var(--diff);"></div></div><div class="barval">${DIFF_N}</div></div>
    <div class="barrow"><div class="barlabel">PROD Only</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${PRODONLY_N})%;background:var(--prodonly);"></div></div><div class="barval">${PRODONLY_N}</div></div>
    <div class="barrow"><div class="barlabel">Git Only</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${FOLDERONLY_N})%;background:var(--folderonly);"></div></div><div class="barval">${FOLDERONLY_N}</div></div>
    <div class="barrow"><div class="barlabel">Identical</div><div class="bartrack"><div class="barfill" style="width:$(bar_pct ${MATCH_N})%;background:var(--match);"></div></div><div class="barval">${MATCH_N}</div></div>
  </div>

  <section>
    <h3><span class="badge diff">1</span> Differences Between Git and PROD</h3>
    <table>
      <tr><th>Procedure</th></tr>
      ${DIFF_ROWS:-<tr><td class=\"empty\">No content differences found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge prodonly">2</span> Present in PROD but Missing in Git</h3>
    <table>
      <tr><th>Procedure</th></tr>
      ${PRODONLY_ROWS:-<tr><td class=\"empty\">None found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge folderonly">3</span> Present in Git but Missing in PROD</h3>
    <table>
      <tr><th>Procedure</th></tr>
      ${FOLDERONLY_ROWS:-<tr><td class=\"empty\">None found.</td></tr>}
    </table>
  </section>

  <section>
    <h3><span class="badge match">4</span> Identical (Git = PROD)</h3>
    <table>
      <tr><th>Procedure</th></tr>
      ${MATCH_ROWS:-<tr><td class=\"empty\">No exact matches found.</td></tr>}
    </table>
  </section>

  <footer>Comparison is word/content-based after stripping comments and whitespace differences. Word diffs above show removed (red, from Git) and added (green, from PROD) tokens.</footer>
</div>
</body>
</html>
HTMLEOF

echo "Done. Dashboard written to: ${OUT_FILE}"
