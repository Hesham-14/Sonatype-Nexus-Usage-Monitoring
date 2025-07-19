#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Usage: nexus_metrics_exporter.sh [window]
#   window: e.g. 1h,12h,24h,48h  (default: 24h)
# ──────────────────────────────────────────────────────────────────────────────

WINDOW="${1:-24h}"
NUM=${WINDOW%h}

# Validate
if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
 echo "ERROR: window must be like 1h,12h,24h,48h" >&2
 exit 2
fi

# ——————— Configuration ——————————————————————————
# cutoff seconds since epoch
CUTOFF=$(date -d "-${NUM} hour" +%s)

# Path to your Nexus log directory
LOG_DIR="/nexus-data/log"
LIVE_LOG="${LOG_DIR}/request.log"

# Where to write the Prom file
OUT_FILE="/app/nexus_api_hits.prom"

# Log filename pattern: request-YYYY-MM-DD.log(.gz)
# Figure out the first calendar date to scan
START_DAY=$(date -d "@$CUTOFF" +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)
# TODAY="2025-05-13"

# Optional: path to a file of custom flags (one per line)
FLAG_FILE="${FLAG_FILE:-/opt/scripts/flags.txt}"

# Helper: emit only lines newer than cutoff
scan_file() {
 file="$1"
 if [ "${file%.gz}" != "$file" ]; then
   zcat "$file"
 else
   cat "$file"
 fi | awk -v cutoff=$CUTOFF '
   {
     sub(/^\[/,"",$4)
     split($4, a, /[\/:]/)
     day=a[1]; mon=a[2]; year=a[3]; hour=a[4]; min=a[5]; sec=a[6]
     m["Jan"]=1; m["Feb"]=2; m["Mar"]=3; m["Apr"]=4
     m["May"]=5; m["Jun"]=6; m["Jul"]=7; m["Aug"]=8
     m["Sep"]=9; m["Oct"]=10; m["Nov"]=11; m["Dec"]=12
     ts = mktime(year " " m[mon] " " day " " hour " " min " " sec)
     if (ts >= cutoff) print
   }'
}

# ──────────────────────────────────────────────────────────────────────────────
# Build /tmp/filtered.log in true time order:
#  1) each archive from START_DAY → yesterday
#  2) then today’s live log
# Temporarily disable pipefail so our grouping redirection can’t die on SIGPIPE
set +o pipefail
{
  # 1) Scan archives from START_DAY → yesterday
  current="$START_DAY"
  while [[ "$current" != "$TODAY" ]]; do
    for ext in gz ""; do
      F="$LOG_DIR/request-$current.log${ext:+.$ext}"
      [[ -f $F ]] && scan_file "$F"
    done
    current=$(date -d "$current +1 day" +%Y-%m-%d)
  done

  # 2) Then scan the live log
  scan_file "$LIVE_LOG"
} > /tmp/filtered.log
set -o pipefail

# ——————— Load log content ————————————————————————
LOG_CONTENT=$(cat "/tmp/filtered.log")

# ——————— 1. Total Requests ——————————————————————
TOTAL_REQUESTS=$(echo "$LOG_CONTENT" | wc -l)

# ——————— 2. Requests Per User —————————————————————
# Assumes user is the 3rd whitespace field
USER_METRICS=$(echo "$LOG_CONTENT" \
| awk '{print $3}' \
| sort | uniq -c \
| awk '{ printf("nexus_custom_exporter_api_requests_by_user{user=\"%s\"} %d\n",$2,$1) }')

# ——————— 3. Top 50 Requested Endpoints ——————————————————
set +o pipefail
ENDPOINT_METRICS=$(echo "$LOG_CONTENT" \
| awk -F'"' '{print $2}' \
| awk '{print $2}' \
| sort | uniq -c \
| sort -nr \
| head -n 50 \
| awk '{ printf("nexus_custom_exporter_api_requests_by_endpoint{endpoint=\"%s\"} %d\n",$2,$1) }')

set -o pipefail

# ——————— 4. Requests Per Repository ——————————————
REPO_METRICS=$(echo "$LOG_CONTENT" \
| awk -F'"' '{print $2}' \
| awk '{print $2}' \
| grep "^/repository/" \
| awk -F'/' '{print "/"$2"/"$3}' \
| sort | uniq -c \
| awk '{ repo=$2; for(i=3;i<=NF;i++) repo=repo"/"$i; printf("nexus_custom_exporter_api_requests_by_repository{repository=\"%s\"} %d\n",repo,$1) }')

# ——————— 5. Requests Per Service ——————————————————
SERVICE_METRICS=$(echo "$LOG_CONTENT" \
| awk -F'"' '{print $2}' \
| awk '{print $2}' \
| grep "^/service/" \
| awk -F'/' '{print "/"$2"/"$3}' \
| sort | uniq -c \
| awk '{ printf("nexus_custom_exporter_api_requests_by_service{service=\"%s\"} %d\n",$2,$1) }')

# ——————— 6. Requests Per Source IP —————————————————
IP_METRICS=$(echo "$LOG_CONTENT" \
| awk '{print $1}' \
| sort | uniq -c \
| awk '{ printf("nexus_custom_exporter_api_requests_by_source_ip{ip=\"%s\"} %d\n",$2,$1) }')

# ——————— 7. Requests Per Hour ————————————————————
# Assumes timestamp like [dd/Mon/yyyy:HH:MM:SS ...]
HOUR_METRICS=$(echo "$LOG_CONTENT" \
| awk -F'[:[]' '{print $3}' \
| sort | uniq -c \
| awk '{ printf("nexus_custom_exporter_api_requests_by_hour{hour=\"%02d\"} %d\n",$2,$1) }')

# ——————— 8. Status Code Distribution —————————————
# Assumes status code is the 9th field
STATUS_METRICS=$(echo "$LOG_CONTENT" \
| awk '{print $9}' \
| sort | uniq -c \
| awk '{ printf("nexus_custom_exporter_api_status_code_total{code=\"%s\"} %d\n",$2,$1) }')

# ——————— 9. Custom Flags ——————————————————————
FLAG_METRICS=""
if [ -f "$FLAG_FILE" ]; then
while IFS= read -r FLAG; do
    COUNT=$(echo "$LOG_CONTENT" | grep -Fxc "$FLAG" || echo 0)
    if [ "$COUNT" -gt 0 ]; then
    # sanitize FLAG if it contains quotes
    esc_flag=$(printf '%s' "$FLAG" | sed 's/"/\\"/g')
    FLAG_METRICS="${FLAG_METRICS}nexus_custom_exporter_api_custom_flag_matches{flag=\"${esc_flag}\"} ${COUNT}\n"
    fi
done < "$FLAG_FILE"
fi

# ——————— Write everything out —————————————————————
cat <<EOF > "$OUT_FILE"
# HELP nexus_custom_exporter_api_requests_total Total number of Nexus REST API requests in last ${NUM}h
# TYPE nexus_custom_exporter_api_requests_total counter
nexus_custom_exporter_api_requests_total ${TOTAL_REQUESTS}

# HELP nexus_custom_exporter_api_requests_by_user Number of Nexus API requests per user in last ${NUM}h
# TYPE nexus_custom_exporter_api_requests_by_user gauge
${USER_METRICS}

# HELP nexus_custom_exporter_api_requests_by_endpoint Number of Nexus API requests per endpoint in last ${NUM}h
# TYPE nexus_custom_exporter_api_requests_by_endpoint gauge
${ENDPOINT_METRICS}

# HELP nexus_custom_exporter_api_requests_by_repository Number of Nexus API requests per repository in last ${NUM}h
# TYPE nexus_custom_exporter_api_requests_by_repository gauge
${REPO_METRICS}

# HELP nexus_custom_exporter_api_requests_by_service Number of Nexus API requests per service path in last ${NUM}h
# TYPE nexus_custom_exporter_api_requests_by_service gauge
${SERVICE_METRICS}

# HELP nexus_custom_exporter_api_requests_by_source_ip Number of Nexus API requests per source IP in last ${NUM}h
# TYPE nexus_custom_exporter_api_requests_by_source_ip gauge
${IP_METRICS}

# HELP nexus_custom_exporter_api_requests_by_hour Number of Nexus API requests per hour in last ${NUM}h (UTC)
# TYPE nexus_custom_exporter_api_requests_by_hour gauge
${HOUR_METRICS}

# HELP nexus_custom_exporter_api_status_code_total Number of Nexus API responses by HTTP status code in last ${NUM}h
# TYPE nexus_custom_exporter_api_status_code_total counter
${STATUS_METRICS}

# HELP nexus_custom_exporter_api_custom_flag_matches Number of log lines matching custom flags in last ${NUM}h
# TYPE nexus_custom_exporter_api_custom_flag_matches gauge
${FLAG_METRICS}
EOF

cat $OUT_FILE 

