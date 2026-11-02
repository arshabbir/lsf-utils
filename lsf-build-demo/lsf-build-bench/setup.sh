#!/bin/bash
# setup.sh - optional helpers for lsf-build-bench
# Author: P M Shabbir Hussain
#
#   ./setup.sh queue [NAME]    LSF administrator: add a build queue (default name: build) that may use
#                              at most one job slot per core on each host in HOSTS, then set QUEUE=NAME
#                              in bench.conf. Every edited LSF file is backed up first.
#   ./setup.sh remove [NAME]   LSF administrator: take that queue and its limit out again
#   ./setup.sh ssh             set up ssh without a password to the hosts (for the CPU figures and
#                              for BASELINE_HOST)

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

# Marker lines around everything setup.sh adds; they name the queue, so two demo queues never mix
# (older versions wrote "# >>> lsf-build-demo queue (added ..." and "# >>> buildfarm demo queues")
set_marks() {
    QMARK="lsf-build-bench queue $QUEUE"
    LMARK="lsf-build-bench limit $QUEUE"
}
set_marks
ANYMARK='lsf-build-(bench|demo) (queue|limit)|buildfarm demo queues'

# ---------------------------------------------------------------- where LSF reads its configuration
conf_files_all() {                       # conf_files_all lsb.queues: LSB_CONFDIR's file, plus bconf's copy if any
    local live
    echo "$(lsb_dir)/$1"
    live=$(live_dir)
    if [ -n "$live" ] && [ -f "$live/$1" ]; then echo "$live/$1"; fi
}
explain_file() {                         # say why this file, when bconf's copy is the one LSF loads
    local live
    live=$(live_dir)
    case "$1" in
        "$live"/*) [ -n "$live" ] || return 0
            echo "  note: bconf has written $(basename "$1") to LSF_LIVE_CONFDIR, so LSF loads that copy and"
            echo "        ignores the one in LSB_CONFDIR (IBM Spectrum LSF 10.1.0, printed p. 1908)" ;;
    esac
}
ckconfig_ok() {                          # badmin ckconfig always exits 0: read its verdict (lsbatch/cmd/badmin.c):
    local out                            # "No errors found." / "There are warning errors." / "There are fatal errors."
    out=$(echo n | LC_ALL=C LANG=C badmin ckconfig 2>&1)
    echo "$out" | grep -qE "No errors found|There are warning errors" && ! echo "$out" | grep -q "There are fatal errors"
}

# ---------------------------------------------------------------- one transaction per run
# Every file is copied once, before its first change, to <file>.before-lsf-build-bench.<run>;
# any failure puts every changed file back.
RUN_ID=$(date +%Y%m%d%H%M%S)-$$
TXN_FILES=()
txn_add() {                              # txn_add FILE: back it up now (once per run); 1 = cannot
    local f=$1 i b
    for i in "${TXN_FILES[@]+"${TXN_FILES[@]}"}"; do [ "$i" = "$f" ] && return 0; done
    [ -f "$f" ] && [ -w "$f" ] && [ -w "$(dirname "$f")" ] ||
        { echo "  cannot write $f or its folder (run as the LSF administrator)"; return 1; }
    b="$f.before-lsf-build-bench.$RUN_ID"
    cp -p "$f" "$b" || { echo "  cannot back up $f"; return 1; }
    TXN_FILES+=("$f")
}
txn_rollback() {
    local f
    for f in "${TXN_FILES[@]+"${TXN_FILES[@]}"}"; do
        cat "$f.before-lsf-build-bench.$RUN_ID" > "$f" && echo "  restored $f"
    done
    TXN_FILES=()
}
txn_report() {
    local f
    for f in "${TXN_FILES[@]+"${TXN_FILES[@]}"}"; do echo "  changed $f (backup: $f.before-lsf-build-bench.$RUN_ID)"; done
}
rewrite() {                              # rewrite FILE AWK-ARGS...: run awk on FILE, write in place (owner and inode kept)
    local f=$1 tmp; shift
    tmp="$f.tmp.$RUN_ID"
    awk "$@" "$f" > "$tmp" && cat "$tmp" > "$f"; local rc=$?
    rm -f "$tmp"
    return $rc
}

# ---------------------------------------------------------------- finding the demo's own blocks
# blocks_ok FILE: every "# >>> <mark>" has its "# <<< <mark>" before the next "# >>>" (else a removal
# could run to the end of the file)
blocks_ok() {
    awk -v any="^# >>> ($ANYMARK)" '
        $0 ~ any { if (open != "") bad = 1; open = substr($0, 7); sub(/ \(.*$/, "", open); next }
        /^# <<< / { m = substr($0, 7); sub(/ \(.*$/, "", m); if (m != open) bad = 1; open = ""; next }
        END { exit (bad || open != "") }' "$1"
}
# demo_blocks FILE: "start end mark" of every demo block that belongs to queue QUEUE: the current
# markers, or an older block whose Queue section is QUEUE_NAME = QUEUE / whose Limit rows use QUEUE
demo_blocks() {
    awk -v any="^# >>> ($ANYMARK)" -v q="$QUEUE" -v qm="$QMARK" -v lm="$LMARK" '
        $0 ~ any { s = NR; m = substr($0, 7); sub(/ \(.*$/, "", m); mine = (m == qm || m == lm); next }
        s && /^[[:space:]]*QUEUE_NAME[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]#].*$/, "", v); if (v == q) mine = 1 }
        s && $1 ~ /^bf_/ && $2 == q { mine = 1 }
        s && /^# <<< / { if (mine) print s, NR, m; s = 0 }' "$1"
}
# old_sections FILE: line ranges of Queue sections QUEUE without markers that an earlier demo wrote
# (recognised only by the demo's exact descriptions)
old_sections() {
    awk -v q="$QUEUE" -v v3="$V3DESC" -v any="^# >>> ($ANYMARK)" '
        $0 ~ any { inblk = 1 } /^# <<< / { inblk = 0; next } inblk { next }
        /^[[:space:]]*Begin[[:space:]]+Queue/ { s = NR; name = ""; demo = 0; next }
        s && /^[[:space:]]*QUEUE_NAME[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]#].*$/, "", v); name = v }
        s && /^[[:space:]]*DESCRIPTION[[:space:]]*=/ { d = $0; sub(/^[^=]*=[[:space:]]*/, "", d); sub(/[[:space:]]*$/, "", d)
                                                         if (d == v3 || index(d, "lsf-build-demo v") == 1) demo = 1 }
        s && /^[[:space:]]*End[[:space:]]+Queue/ { if (name == q && demo) print s, NR; s = 0 }' "$1"
}
queues_in_lines() {                      # queues_in_lines FILE START END: QUEUE_NAMEs defined in those lines
    awk -v a="$2" -v b="$3" 'NR >= a && NR <= b && /^[[:space:]]*QUEUE_NAME[[:space:]]*=/ {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]#].*$/, "", v); print v }' "$1"
}
queue_jobs() {                           # queue_jobs Q: jobs in queue Q ("?" when bjobs cannot tell)
    local out
    out=$(LC_ALL=C bjobs -u all -q "$1" -o jobid -noheader 2>&1)
    case "$out" in
        *"No unfinished job found"*|*"No job found"*|"") echo 0 ;;
        *"No such queue"*) echo 0 ;;
        *[!0-9[:space:]]*) echo "?" ;;
        *) echo "$out" | grep -c '^[0-9]' ;;
    esac
}
# remove_demo FILE: take out the demo's blocks and old sections of QUEUE (with the blank line
# setup.sh put before them); refuses when a queue in them still has jobs
remove_demo() {
    local f=$1 ranges r q n
    blocks_ok "$f" || { echo "  $f: a '# >>> lsf-build-...' block has no matching '# <<<' line; fix it by hand"; return 1; }
    ranges=$( { demo_blocks "$f" | awk '{print $1, $2}'; old_sections "$f"; } )
    [ -n "$ranges" ] || return 0
    while read -r r; do
        for q in $(queues_in_lines "$f" $r); do
            [ "$q" = "$QUEUE" ] && [ "${SKIP_JOBCHECK:-0}" = 1 ] && continue
            n=$(queue_jobs "$q")
            [ "$n" = 0 ] || { echo "  queue $q has jobs ($n); run ./setup.sh clean or wait, then run this again"; return 1; }
        done
    done <<<"$ranges"
    txn_add "$f" || return 1
    rewrite "$f" -v ranges="$(echo "$ranges" | tr '\n' ' ')" '
        BEGIN { n = split(ranges, r, " "); for (i = 1; i < n; i += 2) for (j = r[i]; j <= r[i + 1]; j++) drop[j] = 1 }
        drop[NR] { if (held) held = 0; next }            # a blank line just before a dropped block goes too
        /^[[:space:]]*$/ { if (held) print ""; held = 1; next }
        { if (held) print ""; held = 0; print }
        END { if (held) print "" }' || return 1
    echo "  removed queue $QUEUE (added by this tool) from $f"
}

# ---------------------------------------------------------------- what setup.sh adds
render_queue() {
    local h hosts=""
    for h in "${HOSTS_A[@]}"; do hosts="$hosts $(lsf_name "$h")"; done
    cat <<EOF
# >>> $QMARK (added by setup.sh; remove with: setup.sh remove)
Begin Queue
QUEUE_NAME   = $QUEUE
PRIORITY     = 30
HOSTS        =$hosts
RES_REQ      = order[r15s:ut]
FAIRSHARE    = USER_SHARES[[default,1]]
DESCRIPTION  = $QSIG: C/C++ builds, least-loaded server first, at most one job slot per core (see blimits -a -w)
End Queue
# <<< $QMARK
EOF
}
# PJOB_LIMIT (lsb.queues) and SLOTS_PER_PROCESSOR (lsb.resources) multiply by the processors LSF
# counts on a host. With PARALLEL_SCHED_BY_SLOT=Y (set by the installer in lsb.params) mbatchd
# counts one processor per job slot (MXJ) instead (mbd.init.c / mbd.host.c: numCPUs = maxJobs), so
# on a host with MXJ 5000 "one slot per processor" allows 5000 slots. A vertical Limit table with
# one row per server (printed pp. 1695-1696) caps the queue at the real core count of each server.
render_limit() {                         # fails when a server's name or core count is unknown
    local h n c i=0
    echo "# >>> $LMARK (added by setup.sh; remove with: setup.sh remove)"
    echo "# queue $QUEUE: at most one job slot per core on each server (cores = lshosts ncpus)"
    echo "Begin Limit"
    printf '%-40s %-12s %-36s %s\n' NAME QUEUES HOSTS SLOTS
    for h in "${HOSTS_A[@]}"; do
        i=$((i + 1))
        n=$(lsf_name "$h"); c=$(lsf_cpus "$h")
        [ -n "$n" ] && [ -n "$c" ] || { echo "cannot read the LSF name or the cores of $h" >&2; return 1; }
        printf '%-40s %-12s %-36s %s\n' "$(limit_name "$i" "$h")" "$QUEUE" "$n" "$c"
    done
    echo "End Limit"
    echo "# <<< $LMARK"
}

wait_loaded() {                          # up to 2 minutes until the queue and the limit are both loaded
    local end=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$end" ]; do
        { [ "$(queue_state)" = ours ] && limit_loaded; } && return 0
        printf '.'; sleep 3
    done
    return 1
}

ensure_config() {                        # returns 0 when queue QUEUE and its per-core limit are loaded
    local q r f st qtext ltext rc=0
    q=$(lsb_conf_file lsb.queues) && r=$(lsb_conf_file lsb.resources) ||
        { echo "  could not read the cluster name from lsid"; return 1; }
    st=$(queue_state)
    case "$st" in
        error) echo "  bqueues -l $QUEUE failed: $(LC_ALL=C bqueues -l "$QUEUE" 2>&1 | grep -m1 .)"; return 1 ;;
        other)
            echo "  this cluster already has a queue named $QUEUE that this tool did not create:"
            bqueues -l "$QUEUE" 2>/dev/null | grep -A1 '^QUEUE:' | sed 's/^/    /'
            echo "  use another name, for example:  ./setup.sh queue bfbuild   (then QUEUE=\"bfbuild\" in bench.conf)"
            return 1 ;;
    esac
    qtext=$(render_queue) && ltext=$(render_limit) || return 1
    if [ "$st" = ours ] && limit_loaded &&
       [ "$(sed -n "/^# >>> $QMARK /,/^# <<< $QMARK\$/p" "$q")" = "$qtext" ] &&
       [ "$(sed -n "/^# >>> $LMARK /,/^# <<< $LMARK\$/p" "$r")" = "$ltext" ]; then
        return 0
    fi
    ckconfig_ok || { echo "  the LSF configuration already has errors (badmin ckconfig -v); fix those first"; return 1; }
    if [ ! -f "$r" ]; then                # lsb.resources is optional (printed p. 1694)
        [ -w "$(dirname "$r")" ] && : > "$r" && echo "  created the empty file $r" ||
            { echo "  cannot create $r"; return 1; }
    fi
    [ "$st" = stale ] && echo "  queue $QUEUE was added by an earlier version of this tool: replacing it"
    # the queue being replaced may hold pending jobs of this demo; they stay in the queue
    for f in $(conf_files_all lsb.queues) $(conf_files_all lsb.resources); do
        SKIP_JOBCHECK=1 remove_demo "$f" || { txn_rollback; return 1; }
    done
    { txn_add "$q" && explain_file "$q" && { echo; echo "$qtext"; } >> "$q" &&
      txn_add "$r" && explain_file "$r" && { echo; echo "$ltext"; } >> "$r"; } || { txn_rollback; return 1; }
    echo "  added queue $QUEUE to $q"
    echo "  added its per-core limit to $r:"
    echo "$ltext" | sed -n '/^Begin Limit/,/^End Limit/p' | sed 's/^/      /'
    if ! ckconfig_ok; then
        echo "  badmin ckconfig reports errors:"
        echo n | LC_ALL=C badmin ckconfig -v 2>&1 | grep -iE "error|warning" | head -10 | sed 's/^/    /'
        txn_rollback
        return 1
    fi
    txn_report
    echo "  applying with: badmin reconfig -f   (mbatchd can take a minute)"
    LC_ALL=C badmin reconfig -f 2>&1 | sed 's/^/    /'
    printf '  waiting until LSF has loaded queue %s and its limit ' "$QUEUE"
    if wait_loaded; then
        echo " ready"
    else
        echo " not loaded as written after 2 minutes (queue: $(queue_state); limit loaded: $(limit_loaded && echo yes || echo no))"
        echo "  what badmin ckconfig -v says:"
        echo n | LC_ALL=C badmin ckconfig -v 2>&1 | grep -iE "warning|error|$QUEUE|bf_" | head -15 | sed 's/^/    /'
        rc=1
    fi
    return $rc
}

do_queue() {
    ensure_lsf
    is_lsf_admin || [ "$(id -u)" = 0 ] || die "only an LSF administrator can add a queue (lsclusters -l lists them)"
    resolve_hosts
    echo "Adding queue $QUEUE for: ${HOSTS_A[*]}"
    if ensure_config; then
        echo "queue $QUEUE is ready: $(lsf_total) job slots, at most one per core ($(for h in "${HOSTS_A[@]}"; do printf '%s=%s ' "$(short "$h")" "$(lsf_cpus "$h")"; done | sed 's/ $//'))"
        echo "now set  QUEUE=\"$QUEUE\"  in bench.conf"
    else
        die "queue $QUEUE is not ready (see above)"
    fi
}

do_remove() {                            # take the demo queue and its limit out again (backups kept)
    ensure_lsf
    local f found=0 end
    for f in $(conf_files_all lsb.queues) $(conf_files_all lsb.resources); do
        [ -f "$f" ] || continue
        if [ -n "$(demo_blocks "$f")$(old_sections "$f")" ]; then found=1; fi
    done
    [ "$found" = 1 ] || { echo "nothing of queue $QUEUE from this tool in lsb.queues or lsb.resources"; return 0; }
    for f in $(conf_files_all lsb.queues) $(conf_files_all lsb.resources); do
        [ -f "$f" ] || continue
        remove_demo "$f" || { txn_rollback; die "nothing was removed"; }
    done
    if ! ckconfig_ok; then txn_rollback; die "badmin ckconfig reports errors; the files were restored"; fi
    txn_report
    LC_ALL=C badmin reconfig -f 2>&1 | sed 's/^/  /'
    printf '  waiting for queue %s to go ' "$QUEUE"
    end=$((SECONDS + 120))
    while [ "$(queue_state)" != none ] && [ "$SECONDS" -lt "$end" ]; do printf '.'; sleep 3; done
    echo
    if [ "$(queue_state)" = none ]; then echo "removed queue $QUEUE and its per-core limit"
    else echo "the files are changed, but LSF still shows queue $QUEUE (state: $(queue_state)); check badmin ckconfig -v"; fi
}

do_ssh() {
    ensure_lsf
    resolve_hosts
    echo "Setting up ssh without password for $(id -un) to: ${HOSTS_A[*]}"
    if setup_ssh; then echo "ssh without password works to every host"; else exit 1; fi
}

case "${1:-}" in
    queue) QUEUE=${2:-build}; set_marks; do_queue ;;
    remove) QUEUE=${2:-build}; set_marks; do_remove ;;
    ssh) do_ssh ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
