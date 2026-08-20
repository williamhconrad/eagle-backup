#!/bin/bash
#
# nodehours.sh - record allocation usage at each stage boundary of a cycle.
#
# Sourced by run_cycle.sh. Two independent measures are captured:
#
#   charged   from `sbank`, the authoritative accounting figure (node-hours).
#             Lags slightly behind job completion but is what ALCF bills.
#   pbs       summed from `qstat -xf` resources_used over the jobs this cycle
#             submitted. Exact and immediate, but only counts jobs we launched.
#
# Output: nodehours_iter<N>.csv, one row per stage boundary.
#
# USAGE (from run_cycle.sh):
#   source nodehours.sh
#   nh_init "$ITER"
#   nh_mark "start"
#   ... run a stage ...
#   nh_mark "dock"

NH_CSV=""
NH_START=""

# Charged node-hours from sbank's totals block.
nh_charged() {
    sbank 2>/dev/null \
      | awk '/Charged *:/ {gsub(/,/,"",$3); print $3; exit}' \
      | grep -E '^[0-9.]+$' || echo ""
}

nh_available() {
    sbank 2>/dev/null \
      | awk '/Available Balance:/ {gsub(/,/,"",$3); print $3; exit}' \
      | grep -E '^[0-9.]+$' || echo ""
}

nh_init() {
    local iter="$1"
    NH_CSV="nodehours_iter${iter}.csv"
    if [ ! -f "$NH_CSV" ]; then
        echo "iteration,stage,timestamp,charged_nodehours,available_nodehours,delta_from_previous,cumulative_this_cycle" > "$NH_CSV"
    fi
    NH_START="$(nh_charged)"
    NH_PREV="$NH_START"
    NH_ITER="$iter"
    log "  node-hours at cycle start: ${NH_START:-unavailable}"
}

# nh_mark <stage-label>
nh_mark() {
    local stage="$1"
    local now cur avail delta cum
    now="$(date '+%F %T')"
    cur="$(nh_charged)"
    avail="$(nh_available)"

    if [ -n "$cur" ] && [ -n "$NH_PREV" ]; then
        delta=$(awk -v a="$cur" -v b="$NH_PREV" 'BEGIN{printf "%.2f", a-b}')
    else
        delta=""
    fi
    if [ -n "$cur" ] && [ -n "$NH_START" ]; then
        cum=$(awk -v a="$cur" -v b="$NH_START" 'BEGIN{printf "%.2f", a-b}')
    else
        cum=""
    fi

    echo "${NH_ITER},${stage},${now},${cur},${avail},${delta},${cum}" >> "$NH_CSV"
    log "  node-hours after ${stage}: charged=${cur:-?} (+${delta:-?}), cycle total=${cum:-?}"
    NH_PREV="$cur"
}

# nh_summary - print the CSV at the end of a cycle
nh_summary() {
    [ -f "$NH_CSV" ] || return 0
    echo
    log "node-hour usage for iteration ${NH_ITER}  ($NH_CSV)"
    column -s, -t < "$NH_CSV" | sed 's/^/    /'
}
