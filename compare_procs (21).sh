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
# DEBUG_COMPARE=1 ./compare_procs.sh ... keeps the work directory around
# afterwards (instead of deleting it on exit) and turns on the per-procedure
# diagnostics below (hunk suppression counts, bounded-file dump) - use this
# when an edit you made isn't showing up as a difference, to see exactly
# what the script saw and did at each stage for that procedure.
DEBUG_COMPARE="${DEBUG_COMPARE:-0}"
if [[ "${DEBUG_COMPARE}" != "1" ]]; then
  trap 'rm -rf "${WORKDIR}"' EXIT
else
  echo "[DEBUG_COMPARE=1] Work directory will be KEPT after this run: ${WORKDIR}"
fi
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
collapse_ase_star_expansion() {
  # $1 = input file, $2 = output file
  #
  # sp_showtext (and sp_helptext) has a Sybase/ASE quirk: if a proc's
  # ORIGINAL source contains "select * from X", ASE stores/returns the
  # FULLY EXPANDED column list instead of "*", prefixed with a marker
  # comment: "/* Adaptive Server has expanded all '*' elements ... */".
  # The proc's actual source and behavior are identical to "select *" -
  # this is purely a text-storage side effect on the PROD/ASE side, not a
  # real code difference - so it must not count as one. Git never has this
  # marker (it never runs through ASE), so this is a no-op on Git files.
  #
  # For COMPARISON PURPOSES ONLY, this drops the marker comment and
  # collapses the select list that follows it back down to "*". It does
  # NOT touch the untouched raw file used for the side-by-side display -
  # that continues to show PROD's real, fully-expanded text so nothing is
  # hidden from the user, it's just no longer flagged as a false DIFF.
  #
  # ASE puts the expanded "select ... from ..." text starting on the SAME
  # physical line as the marker comment, right after its closing "*/" -
  # it does NOT appear as a separate following line. For very wide tables
  # the column list can then continue wrapping onto one or more further
  # lines before "from" is finally reached. Both shapes are handled here:
  # the text after the marker's "*/" starts an accumulation buffer, more
  # lines are folded into it if needed, and once a whitespace-bounded
  # "from" is found anywhere in that buffer the whole span collapses down
  # to a single "select * from ..." line (dropping only the marker text
  # and the enumerated columns - never any line that has not been folded
  # into this specific expansion).
  awk '
    function find_after_marker(line, low,    p, rest, restlow, q) {
      p = index(low, "elements")
      if (p == 0) return ""
      rest    = substr(line, p)
      restlow = substr(low, p)
      q = index(restlow, "*/")
      if (q > 0) return substr(rest, q + 2)
      return ""
    }
    function leading_ws(line,    m) {
      m = match(line, /[^ \t]/)
      if (m == 0) return line
      return substr(line, 1, m - 1)
    }
    function last_select_pos(low,    start, idx, abs, last, before, after) {
      # ASE inserts its marker before the START OF THE WHOLE STATEMENT,
      # not necessarily right before "select" - e.g. an insert-select
      # ("insert #t select * from x") or a nested select ("if exists
      # (select * from x)") both get the marker before "insert"/"if",
      # not before "select". Find the LAST stand-alone "select" that
      # appears before the "from" we matched, so any such leading text
      # can be preserved instead of silently discarded. "Stand-alone"
      # (checked via neighbouring chars) avoids matching mid-identifier.
      last = 0
      start = 1
      while ((idx = index(substr(low, start), "select")) > 0) {
        abs = start + idx - 1
        before = (abs == 1) ? "" : substr(low, abs - 1, 1)
        after  = substr(low, abs + 6, 1)
        if (before !~ /[a-z0-9_]/ && after !~ /[a-z0-9_]/) last = abs
        start = abs + 6
      }
      return last
    }
    function try_finalize(buf, ind,    lowbuf, fp, sp, prefix) {
      lowbuf = tolower(buf)
      fp = match(lowbuf, /[[:space:]]from[[:space:]]/)
      if (fp == 0) return ""
      sp = last_select_pos(substr(lowbuf, 1, fp - 1))
      if (sp == 0) return ""
      prefix = substr(buf, 1, sp - 1)
      return ind prefix "select *" substr(buf, fp)
    }
    BEGIN { collecting = 0; acc = ""; indent = "" }
    {
      line = $0
      low  = tolower(line)
      if (!collecting && index(low, "adaptive server has expanded all") > 0 && index(low, "elements") > 0) {
        indent = leading_ws(line)
        acc = find_after_marker(line, low)
        result = try_finalize(acc, indent)
        if (result != "") { print result; acc = ""; next }
        collecting = 1
        next
      }
      if (collecting) {
        acc = acc " " line
        result = try_finalize(acc, indent)
        if (result != "") { print result; collecting = 0; acc = ""; next }
        next
      }
      print line
    }
    END {
      # Safety net: never silently drop content if "from" was never found
      # (should not happen in practice) - surface it raw instead so it is
      # visible as a real DIFF rather than disappearing.
      if (collecting && acc != "") print indent acc
    }
  ' "$1" > "$2"
}

compute_proc_bounds() {
  # $1 = input file
  # Prints "START END" (1-based, inclusive line numbers) to stdout.
  #
  # Bound the comparison to the actual procedure body. A CREATE PROCEDURE
  # statement is always exactly one batch, and batches are delimited by
  # standalone "go" lines - so the true end of the procedure is bounded by
  # the FIRST "go" that appears after the "create procedure" line, not by
  # hunting for "the last end in the file". Git .sql files commonly have a
  # SEPARATE trailing batch after their own "go" (e.g. a deployment
  # confirmation block: "if object_id(...) begin print '<<< CREATED ... >>>'
  # end"), which has its own end/go and must NOT be pulled into the
  # comparison - anchoring on the last end-in-file (an earlier attempt)
  # incorrectly grabbed that block's end instead of the real one. Within
  # that batch boundary we still take the LAST standalone "end" (procedures
  # have nested begin/end blocks from if/while, so the outer close is the
  # last one *inside the batch*). sp_showtext extraction from PROD never
  # includes "go" or trailing batches at all, so this degrades safely to
  # "whole extracted text" on that side. If the create line itself can't be
  # found, fall back to the whole file rather than risk truncating content.
  #
  # Comments are stripped ONLY for the purposes of finding these line
  # numbers (so a "go" or "end" mentioned inside a comment can't fool the
  # boundary detection) - the returned numbers index into the ORIGINAL file.
  sed -e 's#/\*.*\*/##g' "$1" \
    | sed -e 's/--.*$//' \
    | awk '
        { last = NR }
        tolower($0) ~ /^[[:space:]]*create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?(proc|procedure)[[:space:]]/ && start == 0 { start = NR }
        start > 0 && boundary == 0 {
          if (NR > start && tolower($0) ~ /^[[:space:]]*go[[:space:]]*$/) { boundary = NR }
          else if (tolower($0) ~ /^[[:space:]]*end[[:space:];]*$/) { last_end = NR }
        }
        END {
          s = (start > 0) ? start : 1
          limit = (boundary > 0) ? boundary - 1 : last
          e = (last_end > 0) ? last_end : limit
          print s, e
        }
      '
}

extract_proc_body() {
  # $1 = input file, $2 = output file
  #
  # Same bounding as normalize_file, but preserves the ORIGINAL lines
  # exactly as written (formatting, case, comments intact) instead of
  # collapsing/lowercasing them. Used for the human-facing side-by-side
  # diff view, so that content sitting BEFORE the create/create-or-replace
  # procedure line or AFTER the batch's closing "end" (temp-table setup,
  # drop-procedure guards, header comment blocks that only exist on one
  # side, trailing deployment-confirmation batches, etc.) never shows up
  # as a highlighted "difference" - that content was never part of the
  # comparison to begin with.
  local bounds s e
  bounds="$(compute_proc_bounds "$1")"
  s="${bounds%% *}"
  e="${bounds##* }"
  sed -n "${s},${e}p" "$1" > "$2"
}

normalize_file() {
  # $1 = input file, $2 = output file
  local BOUNDED
  BOUNDED="$(mktemp)"
  extract_proc_body "$1" "${BOUNDED}"
  sed -e 's#/\*.*\*/##g' "${BOUNDED}" \
    | sed -e 's/--.*$//' \
    | sed -e '/^[[:space:]]*[Gg][Oo][[:space:]]*$/d' \
    | tr -s '[:space:]' ' ' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/^ *//' -e 's/ *$//' \
    > "$2"
  rm -f "${BOUNDED}"
}

clean_bounded_copy() {
  # $1 = raw input file, $2 = output file
  #
  # Strips stray \r (never part of real content, would otherwise render
  # oddly or cause phantom differences), then trims to the bounded
  # procedure body using the same boundary logic as extract_proc_body,
  # while preserving the ORIGINAL formatting/case/comments. Used both for
  # the existing "differing lines" side-by-side view and for the full-
  # procedure browser panel below, so the two views always agree on
  # exactly which lines constitute "the procedure".
  local NOCR bounds s e
  NOCR="$(mktemp)"
  tr -d '\r' < "$1" > "${NOCR}"
  bounds="$(compute_proc_bounds "${NOCR}")"
  s="${bounds%% *}"
  e="${bounds##* }"
  sed -n "${s},${e}p" "${NOCR}" > "$2"
  rm -f "${NOCR}"
}

js_escape_str() {
  # Escapes a short plain string (no embedded newlines expected, e.g. a
  # procedure name) for safe embedding inside a double-quoted JS string.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_escape_file() {
  # $1 = input file. Prints the file's content escaped for embedding
  # inside a double-quoted JS/JSON string (caller supplies the quotes) -
  # backslashes, double quotes and tabs escaped, real line breaks turned
  # into literal "\n" sequences so the whole file becomes one JS string
  # value the browser can split back into lines with no server involved.
  tr -d '\r' < "$1" | awk '
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      if (NR > 1) printf "\\n"
      printf "%s", $0
    }
  '
}


# ---------------------------------------------------------------------------
# 3. Extract stored procedures from PROD (Sybase ASE)
# ---------------------------------------------------------------------------
echo "[2/5] Querying PROD for stored procedure list..."

PROD_LIST="${WORKDIR}/prod_list.txt"

"${ISQL_BIN}" -U "${SYBASE_USER}" -P "${SYBASE_PASS}" -S "${SYBASE_SERVER}" -D "${SYBASE_DB}" -b -w 8000 <<-EOSQL > "${PROD_LIST}" 2>"${WORKDIR}/prod_list.err"
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
  "${ISQL_BIN}" -U "${SYBASE_USER}" -P "${SYBASE_PASS}" -S "${SYBASE_SERVER}" -D "${SYBASE_DB}" -b -w 8000 <<-EOSQL > "${RAW_FILE}" 2>"${WORKDIR}/prod_raw/${PNAME}.err"
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
  FOR_COMPARE_FILE="${WORKDIR}/prod_raw/${PNAME}.forcompare"
  collapse_ase_star_expansion "${RAW_FILE}" "${FOR_COMPARE_FILE}"
  normalize_file "${FOR_COMPARE_FILE}" "${NORM_FILE}"

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
DIFF_PROC_ENTRIES=""

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

  elif [[ ${IN_SRC} -eq 0 && ${IN_PROD} -eq 1 ]]; then
    PRODONLY_N=$((PRODONLY_N+1))
    PRODONLY_ROWS+="<tr><td>${NAME}</td></tr>"

  elif [[ "${SRC_HASH[${NAME}]}" == "${PROD_HASH[${NAME}]}" ]]; then
    MATCH_N=$((MATCH_N+1))
    MATCH_ROWS+="<tr><td>${NAME}</td></tr>"

  else
    # Build a full side-by-side view: original Git/source content on the
    # left, original PROD content on the right, aligned line by line.
    # Only the lines that actually differ get highlighted - everything
    # else (the bulk of the procedure) shows normally so the user can
    # read the whole thing in context and spot exactly what changed.
    SRC_RAW="${SRC_RAWFILE[${NAME}]}"
    PROD_RAW="${WORKDIR}/prod_raw/${NAME}.sql"
    SRC_NOCR="${WORKDIR}/diffs/${NAME}.src.nocr"
    PROD_NOCR="${WORKDIR}/diffs/${NAME}.prod.nocr"
    SRC_CLEAN="${WORKDIR}/diffs/${NAME}.src.clean"
    PROD_CLEAN="${WORKDIR}/diffs/${NAME}.prod.clean"
    # Strip stray \r so line endings never cause a false "difference"
    tr -d '\r' < "${SRC_RAW}" > "${SRC_NOCR}"
    tr -d '\r' < "${PROD_RAW}" > "${PROD_NOCR}"
    # Bound the DISPLAYED diff to the same create-proc...end range used
    # for the MATCH/DIFF hash comparison above (see extract_proc_body).
    # Without this, anything sitting outside that range on either side -
    # temp-table setup, drop-procedure guards, header comment blocks,
    # trailing deployment-confirmation batches - would show up as a
    # highlighted "difference" even though it was never actually compared.
    #
    # Capture the bounds ourselves (rather than just calling
    # extract_proc_body) so we know the REAL starting line number of the
    # bounded region in each original file. Procs can run thousands of
    # lines long, so instead of rendering every line (forcing the user to
    # scroll past thousands of identical lines to find the handful that
    # differ), we show ONLY the differing hunks, each labelled with the
    # actual line numbers in the Git file and in PROD's extracted text -
    # so the user can jump straight there in their own editor.
    read -r SRC_START SRC_END < <(compute_proc_bounds "${SRC_NOCR}")
    read -r PROD_START PROD_END < <(compute_proc_bounds "${PROD_NOCR}")
    sed -n "${SRC_START},${SRC_END}p"   "${SRC_NOCR}"  > "${SRC_CLEAN}"
    sed -n "${PROD_START},${PROD_END}p" "${PROD_NOCR}" > "${PROD_CLEAN}"

    # Same bounded text also feeds the "1.1" full-procedure viewer below -
    # only built for procedures that end up as a real DIFF (see below).
    GIT_JS="\"$(json_escape_file "${SRC_CLEAN}")\""
    PROD_JS="\"$(json_escape_file "${PROD_CLEAN}")\""


    DIFF_HTML="$(diff "${SRC_CLEAN}" "${PROD_CLEAN}" \
      | awk -v src_off="$((SRC_START-1))" -v prod_off="$((PROD_START-1))" '
          function esc(s) {
            gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
            return s
          }
          function norm_ws_lower(s,   t) {
            # Collapse whitespace and lowercase, for loose content comparison
            t = s
            gsub(/[ \t]+/, " ", t)
            gsub(/^ +/, "", t)
            gsub(/ +$/, "", t)
            return tolower(t)
          }
          function find_after_marker(line, low,    p, rest, restlow, q) {
            p = index(low, "elements")
            if (p == 0) return ""
            rest    = substr(line, p)
            restlow = substr(low, p)
            q = index(restlow, "*/")
            if (q > 0) return substr(rest, q + 2)
            return ""
          }
          function leading_ws(line,    m) {
            m = match(line, /[^ \t]/)
            if (m == 0) return line
            return substr(line, 1, m - 1)
          }
          function last_select_pos(low,    start, idx, abs, last, before, after) {
            # Mirrors last_select_pos() in collapse_ase_star_expansion():
            # the marker sits before the whole statement (e.g. "insert #t
            # select * from x", "if exists (select * from x)"), so keep
            # any such leading text instead of discarding it.
            last = 0
            start = 1
            while ((idx = index(substr(low, start), "select")) > 0) {
              abs = start + idx - 1
              before = (abs == 1) ? "" : substr(low, abs - 1, 1)
              after  = substr(low, abs + 6, 1)
              if (before !~ /[a-z0-9_]/ && after !~ /[a-z0-9_]/) last = abs
              start = abs + 6
            }
            return last
          }
          function normalize_prod_for_compare(   i, low, out, collecting, indent, acc, lowacc, fp, sp, prefix, line) {
            # Mirrors collapse_ase_star_expansion(): the expanded select
            # text starts on the SAME line as the marker comment (right
            # after its closing "*/"), and for wide tables can keep
            # wrapping onto further lines before "from" is reached. Folds
            # the whole span back down to "select * from ..." so this
            # PROD-only storage artifact compares like-for-like against
            # Gits un-expanded "select * from ...".
            #
            # marker_found (global) is set to 1 the moment an actual ASE
            # marker comment is seen. Callers MUST check it: without a
            # marker anywhere in the hunk, the loop below just echoes each
            # PROD line back out unchanged, which - once case/whitespace
            # are normalized by the caller - would spuriously equal a
            # SRC-side line that differs from it ONLY in case or spacing.
            # That false match is what used to make ordinary case-only
            # edits (e.g. IdEN vs IDEN) look like "select *" artifacts and
            # get silently dropped even though no marker was ever present.
            marker_found = 0
            out = ""
            collecting = 0
            for (i = 1; i <= nprod; i++) {
              line = prodlines[i]
              low = tolower(line)
              if (!collecting && index(low, "adaptive server has expanded all") > 0 && index(low, "elements") > 0) {
                marker_found = 1
                indent = leading_ws(line)
                acc = find_after_marker(line, low)
                lowacc = tolower(acc)
                fp = match(lowacc, /[[:space:]]from[[:space:]]/)
                if (fp > 0) {
                  sp = last_select_pos(substr(lowacc, 1, fp - 1))
                  prefix = (sp > 0) ? substr(acc, 1, sp - 1) : ""
                  out = out " " indent prefix "select *" substr(acc, fp); continue
                }
                collecting = 1
                continue
              }
              if (collecting) {
                acc = acc " " line
                lowacc = tolower(acc)
                fp = match(lowacc, /[[:space:]]from[[:space:]]/)
                if (fp > 0) {
                  sp = last_select_pos(substr(lowacc, 1, fp - 1))
                  prefix = (sp > 0) ? substr(acc, 1, sp - 1) : ""
                  out = out " " indent prefix "select *" substr(acc, fp); collecting = 0; acc = ""
                }
                continue
              }
              out = out " " line
            }
            if (collecting && acc != "") out = out " " indent acc
            return out
          }
          function is_ase_star_expansion_only_hunk(   i, sconcat, prod_has_marker, reconstructed) {
            # True when the ENTIRE PROD side of this hunk is nothing but
            # the ASE star-expansion artifact re-stating what Git already
            # says as "select * from ..." - i.e. not a real difference, so
            # it should not be shown to the user as one (see
            # collapse_ase_star_expansion() above for background).
            sconcat = ""
            for (i = 1; i <= nsrc; i++) sconcat = sconcat " " srclines[i]
            sconcat = norm_ws_lower(sconcat)

            # Case 1: FROM was found within this hunk own PROD lines, so
            # the full "select * from ..." could be reconstructed and
            # compared byte-for-byte against Git side. Only trust this if
            # normalize_prod_for_compare() actually saw the ASE marker -
            # otherwise it just echoed PROD lines back unchanged, and a
            # match here would only mean "SRC and PROD are the same string
            # once case/whitespace are ignored", which is also true of
            # plain case-only or whitespace-only edits, not just artifacts.
            reconstructed = normalize_prod_for_compare()
            if (marker_found && norm_ws_lower(reconstructed) == sconcat) return 1

            # Case 2: diff can legitimately exclude the FROM clause from
            # this hunk altogether - it only puts CHANGED lines in a hunk,
            # and if everything from "from" onward is byte-identical on
            # both sides, diff never shows it to us here, so
            # normalize_prod_for_compare() never finds a "from" to
            # collapse against and case 1 above fails even though the
            # hunk IS a pure star-expansion artifact. In that situation
            # this hunk own bounds literally cannot contain a real
            # difference beyond the marker/column-list text itself, so
            # falling back to a narrower check is safe: PROD hunk starts
            # with the ASE marker, and Git side of this same hunk is
            # nothing but (optional leading text plus) "select *" with no
            # trailing content of its own to disagree with.
            prod_has_marker = (nprod > 0 && tolower(prodlines[1]) ~ /adaptive server has expanded all/ && tolower(prodlines[1]) ~ /elements/)
            if (prod_has_marker && sconcat ~ /select \*[[:space:]]*$/) return 1

            return 0
          }
          function flush(   i) {
            if (!have_hunk) return
            total_hunks++
            if (is_ase_star_expansion_only_hunk()) {
              suppressed_hunks++
              # Record WHICH hunk got suppressed and why, so DEBUG_COMPARE
              # runs can show the user exactly what was thrown away instead
              # of it just silently vanishing from the report.
              printf "SUPPRESSED Git line%s %s | PROD line%s %s\n", \
                (nsrc > 1 ? "s" : ""), srclabel, (nprod > 1 ? "s" : ""), prodlabel > "/dev/stderr"
              nsrc = 0; nprod = 0; have_hunk = 0; return
            }
            printf "<tr class=\"hunkhdr\"><td colspan=\"2\">Git line%s %s &nbsp;|&nbsp; PROD line%s %s</td></tr>\n", \
              (nsrc > 1 ? "s" : ""), srclabel, (nprod > 1 ? "s" : ""), prodlabel
            n = (nsrc > nprod) ? nsrc : nprod
            if (n == 0) n = 1
            for (i = 1; i <= n; i++) {
              sline = (i <= nsrc)  ? esc(srclines[i])  : ""
              pline = (i <= nprod) ? esc(prodlines[i]) : ""
              snum  = (i <= nsrc)  ? srcnum[i]  : ""
              pnum  = (i <= nprod) ? prodnum[i] : ""
              printf "<tr class=\"hunkline\"><td><span class=\"lineno\">%s</span>%s</td><td><span class=\"lineno\">%s</span>%s</td></tr>\n", \
                snum, sline, pnum, pline
              # Absolute (original-file) differing line numbers, collected
              # so the caller can also highlight these same lines in the
              # full-procedure side-by-side browser (section 1.1) instead
              # of that view only ever showing plain, undifferentiated text.
              if (snum != "") { gitdiff_n++; gitdiff_lines[gitdiff_n] = snum }
              if (pnum != "") { proddiff_n++; proddiff_lines[proddiff_n] = pnum }
            }
            nsrc = 0; nprod = 0; have_hunk = 0
          }
          {
            if (match($0, /^[0-9]+(,[0-9]+)?[acd][0-9]+(,[0-9]+)?$/)) {
              flush()
              have_hunk = 1
              hdr = $0
              typepos = 0
              for (p = 1; p <= length(hdr); p++) {
                ch = substr(hdr, p, 1)
                if (ch == "a" || ch == "c" || ch == "d") { typepos = p; break }
              }
              split(substr(hdr, 1, typepos-1), la, ",")
              split(substr(hdr, typepos+1), ra, ",")
              l1 = la[1] + 0; l2 = (la[2] == "" ? l1 : la[2] + 0)
              r1 = ra[1] + 0; r2 = (ra[2] == "" ? r1 : ra[2] + 0)
              if (l1 == 0) { srclabel = "(insertion point)"; nextsrcnum = 0 }
              else { srclabel = (l1+src_off) (l2>l1 ? "-" (l2+src_off) : ""); nextsrcnum = l1+src_off }
              if (r1 == 0) { prodlabel = "(insertion point)"; nextprodnum = 0 }
              else { prodlabel = (r1+prod_off) (r2>r1 ? "-" (r2+prod_off) : ""); nextprodnum = r1+prod_off }
              nsrc = 0; nprod = 0
              next
            }
            if ($0 == "---") next
            if (substr($0, 1, 2) == "< ") { nsrc++; srclines[nsrc] = substr($0,3); srcnum[nsrc] = nextsrcnum++; next }
            if (substr($0, 1, 2) == "> ") { nprod++; prodlines[nprod] = substr($0,3); prodnum[nprod] = nextprodnum++; next }
          }
          END {
            flush()
            printf "HUNKSTATS total=%d suppressed=%d shown=%d\n", total_hunks+0, suppressed_hunks+0, (total_hunks+0)-(suppressed_hunks+0) > "/dev/stderr"
            gl = ""; for (i = 1; i <= gitdiff_n; i++)  gl = gl (i>1?",":"") gitdiff_lines[i]
            pl = ""; for (i = 1; i <= proddiff_n; i++) pl = pl (i>1?",":"") proddiff_lines[i]
            printf "GITDIFFLINES %s\n", gl > "/dev/stderr"
            printf "PRODDIFFLINES %s\n", pl > "/dev/stderr"
          }
        ' 2>"${WORKDIR}/diffs/${NAME}.hunkstats")"

    DIFF_HTML_TRIMMED="$(printf '%s' "${DIFF_HTML}" | tr -d '[:space:]')"

    # Surface hunk-suppression so it's never silent: if the ASE select-*
    # expansion filter (is_ase_star_expansion_only_hunk) throws away a real
    # hunk, that used to just look like "fewer differences than expected"
    # with no trace. Now it's logged per procedure, and kept for inspection
    # under DEBUG_COMPARE=1.
    HUNKSTATS_FILE="${WORKDIR}/diffs/${NAME}.hunkstats"
    SUPPRESSED_N="$(sed -n 's/^HUNKSTATS .*suppressed=\([0-9]*\).*/\1/p' "${HUNKSTATS_FILE}" 2>/dev/null)"
    if [[ -n "${SUPPRESSED_N}" && "${SUPPRESSED_N}" -gt 0 ]]; then
      echo "       NOTE: ${NAME}: ${SUPPRESSED_N} hunk(s) auto-suppressed as ASE 'select *' expansion artifacts."
      echo "             If you expected to see a difference here, set DEBUG_COMPARE=1 and check:"
      echo "             ${HUNKSTATS_FILE}"
    fi

    # Convert the absolute (original-file) differing line numbers reported
    # by the diff awk pass into positions within the bounded excerpt
    # (1-based from the start of the procedure body), so they line up with
    # how section 1.1's full-procedure browser numbers its lines below.
    GIT_ABS_LINES="$(sed -n 's/^GITDIFFLINES //p' "${HUNKSTATS_FILE}" 2>/dev/null)"
    PROD_ABS_LINES="$(sed -n 's/^PRODDIFFLINES //p' "${HUNKSTATS_FILE}" 2>/dev/null)"
    GIT_LINES_REL=""
    [[ -n "${GIT_ABS_LINES}" ]] && GIT_LINES_REL="$(printf '%s' "${GIT_ABS_LINES}" | tr ',' '\n' | awk -v off="$((SRC_START-1))" 'NF{print $1-off}' | paste -sd, -)"
    PROD_LINES_REL=""
    [[ -n "${PROD_ABS_LINES}" ]] && PROD_LINES_REL="$(printf '%s' "${PROD_ABS_LINES}" | tr ',' '\n' | awk -v off="$((PROD_START-1))" 'NF{print $1-off}' | paste -sd, -)"

    if [[ -z "${DIFF_HTML_TRIMMED}" ]]; then
      # Every hunk the raw diff produced turned out to be a false positive
      # (fully explained by a known display-only artifact, e.g. ASE's
      # select-star expansion) and got suppressed - so despite the hash
      # mismatch that got us into this branch, there is nothing left to
      # show the user as a real difference. Reclassify as MATCH instead
      # of leaving an empty "Differences" row with nothing inside it.
      STATUS="MATCH"
      MATCH_N=$((MATCH_N+1))
      MATCH_ROWS+="<tr><td>${NAME}</td></tr>"
    else
      DIFF_N=$((DIFF_N+1))
      DIFF_ROWS+="<tr id=\"diffrow-${NAME}\" class=\"diffrow\" onclick=\"toggleDiff('${NAME}')\">
      <td>${NAME} <span class=\"expand-hint\">(click to view differing lines)</span></td></tr>
      <tr id=\"diff-${NAME}\" class=\"diffdetail\" style=\"display:none\">
      <td><div class=\"diffbox\"><table class=\"sbsdiff\">
        <tr class=\"sbs-hdr\"><th>Git</th><th>PROD</th></tr>
        ${DIFF_HTML}
      </table></div></td></tr>"
      DIFF_PROC_ENTRIES+="\"$(js_escape_str "${NAME}")\":{\"git\":${GIT_JS},\"prod\":${PROD_JS},\"gitLines\":[${GIT_LINES_REL}],\"prodLines\":[${PROD_LINES_REL}]},
"
    fi
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
    padding:0;border-radius:8px;max-height:420px;overflow-y:auto;overflow-x:hidden;line-height:1.5;}
  table.sbsdiff{width:100%;table-layout:fixed;border-collapse:collapse;font-size:12px;}
  table.sbsdiff td, table.sbsdiff th{
    width:50%;padding:3px 10px;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;
    border-bottom:1px solid #1e293b;vertical-align:top;
  }
  table.sbsdiff th{
    position:sticky;top:0;background:#0f1724;color:#93c5fd;text-align:left;
    text-transform:uppercase;font-size:11px;letter-spacing:.05em;padding:8px 10px;
    border-bottom:1px solid #334155;
  }
  table.sbsdiff td:first-child{border-right:1px solid #1e293b;}
  tr.hunkhdr td{
    background:#1e293b;color:#93c5fd;font-weight:700;font-size:11px;
    text-transform:uppercase;letter-spacing:.04em;padding:6px 10px;
  }
  tr.hunkline td{background:#3b0d0d;color:#fecaca;}
  tr.hunkline td:last-child{background:#0d2e17;color:#bbf7d0;}
  .lineno{display:inline-block;min-width:42px;color:#64748b;font-weight:600;margin-right:8px;}
  .empty{color:var(--muted);font-style:italic;padding:10px 0;}
  .badge.sub{background:#0891b2;font-size:11px;padding:2px 8px;}
  .detail-controls{display:flex;align-items:center;gap:10px;margin-bottom:14px;flex-wrap:wrap;}
  .detail-controls label{font-size:12.5px;color:var(--muted);font-weight:600;}
  #diffDetailSelect{padding:7px 10px;border:1px solid var(--line);border-radius:8px;font-size:13px;font-family:inherit;min-width:260px;max-width:420px;}
  #diffDetailSelect:focus{outline:2px solid #fca5a5;outline-offset:1px;}
  .browse-panels{display:grid;grid-template-columns:1fr 1fr;border-radius:8px;overflow:hidden;border:1px solid #1e293b;}
  .browse-col{background:#0b1220;min-width:0;border-right:1px solid #1e293b;}
  .browse-col:last-child{border-right:none;}
  .browse-colhdr{position:sticky;top:0;background:#0f1724;color:#93c5fd;font-size:11px;text-transform:uppercase;letter-spacing:.05em;padding:8px 10px;border-bottom:1px solid #334155;}
  .browse-pane{margin:0;padding:10px;color:#e2e8f0;font-family:Consolas,monospace;font-size:12px;line-height:1.6;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;max-height:480px;overflow-y:auto;}
  .browse-pane .ln{display:inline-block;min-width:38px;color:#64748b;font-weight:600;margin-right:8px;user-select:none;}
  .browse-missing{color:#f87171;font-style:italic;padding:2px 0;}
  .browse-pane .diffline{display:block;margin:0 -10px;padding:0 10px;}
  .browse-pane .diffline.git,.browse-pane .diffline.prod{background:#7a5c00;color:#fff7d6;}
  footer{color:var(--muted);font-size:12px;text-align:center;padding:20px 0 40px 0;}
  @media (max-width:900px){.cards{grid-template-columns:repeat(2,1fr);}}
</style>
<script>
  function toggleDiff(name){
    var row = document.getElementById('diff-' + name);
    if(!row) return;
    var opening = (row.style.display === 'none' || row.style.display === '');
    row.style.display = opening ? 'table-row' : 'none';
    // Clicking a procedure in section 1 should take the user straight to
    // its difference, not leave them to separately go find it in the 1.1
    // dropdown below - so keep the two views in sync automatically.
    if (opening) {
      var sel = document.getElementById('diffDetailSelect');
      if (sel && sel.value !== name) { sel.value = name; }
      if (typeof showDiffDetail === 'function') showDiffDetail(name);
    }
  }

  // Full bounded Git/PROD text, but ONLY for procedures that ended up as
  // a real DIFF (see the reclassification in the build script - a
  // procedure whose only apparent differences turned out to be display
  // artifacts, e.g. ASE's select-star expansion, is never in here).
  const DIFF_PROC_DATA = {
${DIFF_PROC_ENTRIES}
  };

  function renderPane(el, text, diffLines){
    el.innerHTML = '';
    if(text === null || text === undefined){
      var d = document.createElement('div');
      d.className = 'browse-missing';
      d.textContent = 'Not present here.';
      el.appendChild(d);
      return null;
    }
    var diffSet = {};
    if (diffLines) { for (var k = 0; k < diffLines.length; k++) diffSet[diffLines[k]] = true; }
    var lines = text.length ? text.split('\n') : [''];
    var frag = document.createDocumentFragment();
    var firstDiffEl = null;
    for (var i = 0; i < lines.length; i++){
      var lineNo = i + 1;
      var isDiff = !!diffSet[lineNo];
      var wrap = document.createElement('span');
      wrap.className = 'diffline' + (isDiff ? (' ' + el.dataset.side) : '');
      var ln = document.createElement('span');
      ln.className = 'ln';
      ln.textContent = String(lineNo);
      wrap.appendChild(ln);
      wrap.appendChild(document.createTextNode(lines[i] + '\n'));
      frag.appendChild(wrap);
      if (isDiff && !firstDiffEl) firstDiffEl = wrap;
    }
    el.appendChild(frag);
    return firstDiffEl;
  }
  function showDiffDetail(name){
    var entry = DIFF_PROC_DATA[name];
    var empty = document.getElementById('diffDetailEmpty');
    var panels = document.getElementById('diffDetailPanels');
    if(!entry){
      panels.style.display = 'none';
      empty.style.display = 'block';
      empty.textContent = 'Select a procedure above to see its full Git and PROD source side by side.';
      return;
    }
    empty.style.display = 'none';
    panels.style.display = 'grid';
    var gitPane = document.getElementById('diffDetailGitPane');
    var prodPane = document.getElementById('diffDetailProdPane');
    gitPane.dataset.side = 'git';
    prodPane.dataset.side = 'prod';
    var firstGit = renderPane(gitPane, entry.git, entry.gitLines);
    var firstProd = renderPane(prodPane, entry.prod, entry.prodLines);
    // Jump straight to the actual difference on BOTH sides instead of
    // leaving the user to scroll through the whole procedure body (or the
    // other pane) looking for it.
    if (firstGit) firstGit.scrollIntoView({block:'center'});
    if (firstProd) firstProd.scrollIntoView({block:'center'});
  }
  document.addEventListener('DOMContentLoaded', function(){
    // Section 1.1's dropdown only ever lists procedures that are real,
    // final differences - built from DIFF_PROC_DATA, which already
    // excludes anything reclassified as identical.
    var diffSelect = document.getElementById('diffDetailSelect');
    if (diffSelect){
      var diffNames = Object.keys(DIFF_PROC_DATA).sort(function(a,b){ return a.localeCompare(b); });
      for (var j = 0; j < diffNames.length; j++){
        var dopt = document.createElement('option');
        dopt.value = diffNames[j];
        dopt.textContent = diffNames[j];
        diffSelect.appendChild(dopt);
      }
      diffSelect.addEventListener('change', function(){ showDiffDetail(this.value); });
    }
  });
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
    <h3><span class="badge sub">1.1</span> Full Procedure Comparison (Differing Procedures Only)</h3>
    <div class="detail-controls">
      <label for="diffDetailSelect">Select a procedure:</label>
      <select id="diffDetailSelect">
        <option value="">${DIFF_N} procedure(s) with differences...</option>
      </select>
    </div>
    <div id="diffDetailEmpty" class="empty">Select a procedure above to see its full Git and PROD source side by side.</div>
    <div id="diffDetailPanels" class="browse-panels" style="display:none">
      <div class="browse-col">
        <div class="browse-colhdr">Git</div>
        <pre id="diffDetailGitPane" class="browse-pane"></pre>
      </div>
      <div class="browse-col">
        <div class="browse-colhdr">PROD</div>
        <pre id="diffDetailProdPane" class="browse-pane"></pre>
      </div>
    </div>
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


  <footer>Comparison is content-based after stripping comments and whitespace differences. Each expanded row shows only the lines that actually differ, labelled with their real line numbers in the Git file (left, red) and PROD's extracted text (right, green) - not the full procedure.</footer>
</div>
</body>
</html>
HTMLEOF

echo "Done. Dashboard written to: ${OUT_FILE}"
