#!/bin/bash
# steps.sh - a guided tour: building C/C++ with LSF, step by step (uses the sample project)
# Author: P M Shabbir Hussain
#
#   ./steps.sh 1      the hosts LSF sees
#   ./steps.sh 2      one compile: on this host, then on the host LSF picks
#   ./steps.sh 3      a full build as an LSF batch job
#   ./steps.sh 4      many builds at once: LSF spreads them over the hosts
#   ./steps.sh 5      one large build over all hosts with lsmake
#   ./steps.sh 6      who used what: accounting
#   ./steps.sh all    steps 1 to 6
#
# Every LSF command is printed before it runs, followed by its output.
# PAUSE=0 runs without waiting for Enter between commands.

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

need_setup() {
    gen_sample
    bqueues "$QUEUE" >/dev/null 2>&1 || die "queue $QUEUE does not exist: set QUEUE in bench.conf (./bench.sh check)"
    mkdir -p "$WORKDIR/builds" || die "cannot write $WORKDIR"
}
COMPILE="g++ -O2 -std=c++11 -Iinclude -c src/unit_000.cpp -o /tmp/lsfbench-$(id -un)-unit_000.o"

step1() {
    banner "Step 1/6: the hosts LSF sees"
    say "Every host reports its cores and load to LSF every few seconds"
    show "lshosts -w ${HOSTS_A[*]}"
    show "lsload -w -I r15s:ut:mem ${HOSTS_A[*]}"
    show "bhosts -w ${HOSTS_A[*]}"
    show "bqueues -w $QUEUE"
}

step2() {
    need_setup
    banner "Step 2/6: one compile, on this host and on the host LSF picks"
    cd "$SRC" || die "cannot cd to $SRC"
    say "Today: the developer compiles on the server they are logged in to"
    show "hostname -s && $COMPILE && echo compiled OK"
    say "With LSF: the same command; LSF picks the least-loaded host and runs it there"
    if remote_ok; then
        show "lsrun -R 'order[r15s:ut]' -m '${HOSTS_A[*]}' sh -c 'hostname -s && $COMPILE && echo compiled OK'"
    else
        say "(lsrun is for LSF administrators here (LSF_DISABLE_LSRUN=Y), so this uses a batch job and waits for it: bsub -K)"
        local out=$WORKDIR/builds/compile.$$.out
        show "bsub -K -q $QUEUE -R 'order[r15s:ut]' -m '${HOSTS_A[*]}' -o $out sh -c 'hostname -s && $COMPILE && echo compiled OK' && job_output $out"
    fi
}

step3() {
    need_setup
    banner "Step 3/6: a full build as an LSF batch job"
    local id out
    id=bf_one_$(date +%H%M%S)
    out=$WORKDIR/builds/$id
    mkdir -p "$out"
    say "Submit: LSF finds a host with $SLOTS free cores; build.sh compiles with make -j$SLOTS"
    show "bsub -q $QUEUE -m '${HOSTS_A[*]}' -n $SLOTS -R 'span[hosts=1]' -J $id -o $out/lsf.out $SRC/build.sh $SRC $out"
    sleep 3
    show "bjobs -w -J $id"
    if command -v bwait >/dev/null 2>&1; then
        show "bwait -w 'ended($id)' -t 15"
    else
        printf 'waiting for the job '
        while bjobs -J "$id" 2>/dev/null | grep -qE ' (PEND|RUN) '; do printf '.'; sleep 2; done; echo
    fi
    show "bjobs -a -w -J $id"
    say "The artifact and the build log are on the shared folder"
    show "ls -l $out"
    show "grep -A 12 'Resource usage summary' $out/lsf.out"
}

step4() {
    need_setup
    banner "Step 4/6: many builds at once, LSF spreads them over the hosts"
    local n tag t=0 want
    n=${N:-$(( $(lsf_total) / SLOTS ))}
    [ "$n" -ge "$NH" ] || n=$NH
    wait_my_jobs || return 0
    tag=many$(date +%H%M%S)
    say "$n developers press 'build' at the same moment ($SLOTS cores each)"
    PAUSE=0 show "$BF storm -via lsf -queue $QUEUE -hosts '${HOSTS_A[*]}' -src $SRC -out $WORKDIR/builds -tag $tag -n $n -slots $SLOTS -nowait"
    # no pause here: the builds are short, and the next views are only meaningful while they run
    while [ "$(bjobs -p -o jobid -noheader -J "bf_${tag}_*" 2>/dev/null | grep -c '^[0-9]')" -gt 0 ] && [ "$t" -lt 30 ]; do
        sleep 1; t=$((t + 1))
    done
    say "Running builds and job slots per host now (from bjobs -r -o 'job_name exec_host')"
    if limit_loaded; then
        PAUSE=0 show "spread '^bf_${tag}_'"
        # blimits' usage counts can trail the dispatch by a few seconds: wait until they match
        want=$(bjobs -r -o 'job_name nalloc_slot' -noheader 2>/dev/null | awk -v p="^bf_${tag}_" '$1 ~ p {s += $2} END {print s + 0}')
        t=0
        while [ "$(blimits -w 2>/dev/null | awk -v p="^bf_${QUEUE}_" '$1 ~ p {split($7, a, "/"); s += a[1]} END {print s + 0}')" -lt "$want" ] && [ "$t" -lt 20 ]; do
            sleep 1; t=$((t + 1))
        done
        say "LSF's own view of the per-core limit: job slots in use / cores, per host ('-' = none)"
        show "blimits -a -w | grep -E '^ *NAME|bf_${QUEUE}_'"
    else
        show "spread '^bf_${tag}_'"
    fi
    say "LSF runs as many builds as fit on each host and queues the rest"
    show "bjobs -w -J 'bf_${tag}_*'"
    printf 'waiting for the builds to finish '
    t=0
    while [ -n "$(bjobs -o 'jobid job_name' -noheader 2>/dev/null | awk -v p="^bf_${tag}_" '$2 ~ p')" ] && [ "$t" -lt 1800 ]; do
        printf '.'; sleep 3; t=$((t + 3))
    done
    echo
    show "$BF report -out $WORKDIR/builds -tags $tag"
}

step5() {
    need_setup
    banner "Step 5/6: one large build over all hosts with lsmake"
    if ! command -v lsmake >/dev/null 2>&1; then say "lsmake is not installed on this cluster - skipping"; return 0; fi
    if ! remote_ok; then
        say "lsmake can only use other hosts for LSF administrators here (LSF_DISABLE_LSRUN=Y) - skipping"
        return 0
    fi
    local total mode
    total=$(lsf_total)
    mode=$(lsmake_mode)
    cd "$BIG" || die "cannot cd to $BIG"
    say "Same Makefile, $(nfiles "$BIG") C++ files: lsmake runs the tasks on $NH hosts ($total cores)"
    show "make clean >/dev/null"
    if [ "$mode" = batch ]; then
        if ! wait_my_jobs || ! wait_hosts_ok 120; then say "skipping this step: lsmake needs all $total cores free"; return 0; fi
        local out=$WORKDIR/builds/lsmake.$$.out
        pending_watch 60
        say "(bsub -K waits for the job; lsmake's output goes to $out)"
        show "time bsub -K -q $QUEUE -m '${HOSTS_A[*]}' -n $total -o $out lsmake -V -y; job_output $out | lsmake_view"
        kill "$WATCH_PID" 2>/dev/null
    else
        say "(lsmake -m: the exact cores of each host; this cluster lets a host run more job slots than cores)"
        show "time lsmake -m '$(lsmake_hosts)' -V -y 2>&1 | lsmake_view"
    fi
    say "(build lines and lsmake's per-task host lines are condensed into the count above;"
    say " -y prints the summary: the slots each host gave the build)"
}

step6() {
    banner "Step 6/6: who used what, accounting"
    show "bacct -u all -q $QUEUE"
    show "bjobs -a -o 'jobid user stat exec_host:40 run_time' | head -n 16"
}

ensure_lsf
resolve_hosts
case "${1:-}" in
    [1-6]) tmux_tip; "step$1" ;;
    all) tmux_tip; for i in 1 2 3 4 5 6; do "step$i"; done ;;
    *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
