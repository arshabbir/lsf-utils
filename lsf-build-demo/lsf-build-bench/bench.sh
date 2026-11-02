#!/bin/bash
# bench.sh - benchmark C/C++ builds: one server versus IBM Spectrum LSF
# Author: P M Shabbir Hussain
#
#   ./bench.sh check     check the cluster and the settings in bench.conf (changes nothing in LSF)
#   ./bench.sh run       check, run the benchmark and write the report
#   ./bench.sh report    show the last report again
#   ./bench.sh clean     stop your jobs of this tool that are still in LSF
#
# The tests (TESTS in bench.conf):
#   1  N clean builds at the same time: all on one server, then through bsub (LSF picks the hosts)
#   2  one large clean build: make -j<cores> on one server, then lsmake on the cores of all hosts

# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

npass=0; nwarn=0; nfail=0
ok()   { echo "  PASS  $*"; npass=$((npass + 1)); }
warn() { echo "  WARN  $*"; nwarn=$((nwarn + 1)); }
bad()  { echo "  ${c_bad}FAIL${c_off}  $*"; nfail=$((nfail + 1)); }
info() { echo "  INFO  $*"; }
q() { printf '%q' "$1"; }

# baseline: BH = what buildfarm runs on (local or a host name), BNAME = its name, BCORES = its cores
baseline() {
    if is_local "$BASELINE_HOST"; then BH=local; BNAME=$(local_host); else BH=$BASELINE_HOST; BNAME=$(short "$BASELINE_HOST"); fi
    BCORES=$(lsf_cpus "$BNAME")
    if [ -z "$BCORES" ] && [ "$BH" = local ]; then BCORES=$(nproc 2>/dev/null); fi
    BCORES=${BCORES:-0}
}

do_check() {
    ensure_lsf
    local h c m st cl out p tool v diff miss token mode
    echo "Checking as $(id -un) on $(local_host) (settings: $( [ -f "$CONF" ] && echo "$CONF" || echo "defaults, no bench.conf"))"
    cl=$(cluster_name)
    if [ -n "$cl" ]; then ok "LSF cluster $cl is up"; else bad "lsid failed: is LSF running, is profile.lsf sourced?"; return 1; fi
    resolve_hosts
    info "hosts ($NH): $(for h in "${HOSTS_A[@]}"; do printf '%s ' "$(short "$h")"; done)"
    for h in "${HOSTS_A[@]}"; do
        st=$(bhosts -w "$h" 2>/dev/null | awk 'NR == 2 {print $2}')
        c=$(lsf_cpus "$h"); m=$(lsf_maxslots "$h")
        if [ -z "$st" ]; then bad "$h: not an LSF server host (bhosts -w $h)"; continue; fi
        if [ -z "$c" ]; then bad "$h: lshosts does not report its cores"; continue; fi
        case "$st" in
            ok) ok "$h: ok, $c cores, $m job slots" ;;
            closed_Full) warn "$h: ok but full right now (bhosts -w: closed_Full); LSF builds wait for free slots" ;;
            *) bad "$h is $st (bhosts -w); it cannot take jobs" ;;
        esac
    done
    local qok=0
    if bqueues "$QUEUE" >/dev/null 2>&1; then
        qok=1
        st=$(bqueues "$QUEUE" 2>/dev/null | awk 'NR == 2 {print $3}')
        case "$st" in Open:Active) ok "queue $QUEUE is $st" ;; *) bad "queue $QUEUE is $st (bqueues $QUEUE)" ;; esac
    else
        bad "queue $QUEUE does not exist (bqueues): set QUEUE in bench.conf"
    fi

    mkdir -p "$WORKDIR/check" 2>/dev/null && [ -w "$WORKDIR" ] || { bad "cannot write $WORKDIR (WORKDIR)"; return 1; }
    if [ -n "$REPO" ]; then
        if [ -d "$REPO" ]; then ok "project $REPO ($(nfiles "$REPO") C/C++ files)"; else bad "REPO $REPO does not exist"; fi
        if [ -z "$CONFIGURE" ] && [ ! -f "$REPO/$BUILD_DIR/Makefile" ] && [ ! -f "$REPO/$BUILD_DIR/makefile" ] && [ ! -f "$REPO/$BUILD_DIR/GNUmakefile" ]; then
            bad "no Makefile in $REPO/$BUILD_DIR and no CONFIGURE command: set CONFIGURE and BUILD_DIR in bench.conf"
        fi
    else
        gen_sample
        ok "no REPO set: using the sample C++ projects in $SAMPLE"
    fi

    baseline
    if [ "$BH" = local ]; then
        ok "baseline (one server) = this host, $BNAME, $BCORES cores"
    elif ssh_host_ok "$BASELINE_HOST"; then
        ok "baseline (one server) = $BNAME over ssh, $BCORES cores"
    else
        bad "baseline host $BASELINE_HOST: ssh without a password does not work (./setup.sh ssh), or leave BASELINE_HOST empty"
    fi
    [ "$BCORES" -gt 0 ] || bad "cannot read the cores of the baseline host $BNAME"

    if [ "$qok" = 0 ]; then
        echo "Result: $npass passed, $nwarn warnings, $nfail failed (the checks on the hosts need a queue)"
        return 1
    fi
    # one small batch job per host: shared folder, project path, local scratch, tools
    token="$(local_host)-$$-$(date +%s)"
    echo "$token" > "$WORKDIR/check/token"
    p=$(project_for 2)
    {
        echo '#!/bin/sh'
        echo 'echo "BFCHECK host=$(hostname -s)"'
        echo "echo \"BFCHECK token=\$(cat $(q "$WORKDIR/check/token") 2>/dev/null)\""
        echo "if [ -d $(q "$p") ]; then echo 'BFCHECK project=yes'; else echo 'BFCHECK project=no'; fi"
        echo "if mkdir -p $(q "$SCRATCH") && t=\$(mktemp -d $(q "$SCRATCH")/lsfbench.XXXXXX) && rmdir \"\$t\"; then echo 'BFCHECK scratch=yes'; else echo 'BFCHECK scratch=no'; fi"
        for tool in $TOOLS; do
            echo "v=\$($(q "$tool") --version 2>/dev/null | head -1); echo \"BFCHECK tool.$tool=\${v:-missing}\""
        done
    } > "$WORKDIR/check/check-host.sh"
    echo "  ....  running a check job on every host (bsub -q $QUEUE -m <host>) ..."
    on_hosts "$WORKDIR/check/check-host.sh" 180
    declare -A tver=()
    diff=""; miss=""
    for h in "${HOSTS_A[@]}"; do
        out="$WORKDIR/check/check-host.sh.$(short "$h").out"
        if ! grep -q '^BFCHECK host=' "$out" 2>/dev/null; then
            if grep -q "is submitted" "${out%.out}.bsub" 2>/dev/null || [ ! -s "${out%.out}.bsub" ]; then
                bad "$(short "$h"): the check job did not run within 3 minutes (bsub -q $QUEUE -m $h); see $out"
            else
                bad "$(short "$h"): bsub -q $QUEUE -m $h failed: $(grep -m1 . "${out%.out}.bsub")"
            fi
            continue
        fi
        if grep -qx "BFCHECK token=$token" "$out"; then ok "$(short "$h"): sees $WORKDIR (shared)"
        else bad "$(short "$h"): does not see $WORKDIR - WORKDIR must be on a folder shared by all hosts at the same path"; fi
        if grep -qx 'BFCHECK project=yes' "$out"; then ok "$(short "$h"): sees the project $p"
        else bad "$(short "$h"): does not see $p - the project must be on the shared folder"; fi
        grep -qx 'BFCHECK scratch=yes' "$out" || bad "$(short "$h"): cannot write $SCRATCH (SCRATCH, local disk for test 1)"
        for tool in $TOOLS; do
            v=$(sed -n "s/^BFCHECK tool\.$tool=//p" "$out" | head -1)
            if [ "$v" = missing ] || [ -z "$v" ]; then miss="$miss $(short "$h"):$tool"; continue; fi
            if [ -z "${tver[$tool]:-}" ]; then tver[$tool]=$v
            elif [ "${tver[$tool]}" != "$v" ] && [[ " $diff " != *" $tool "* ]]; then diff="$diff $tool"; fi
        done
    done
    if [ -n "$miss" ]; then bad "tools missing:$miss (TOOLS in bench.conf)"; fi
    if [ -n "$diff" ]; then warn "different versions on the hosts of:$diff - every host should build with the same toolchain"
    elif [ -z "$miss" ]; then
        for tool in $TOOLS; do ok "$tool: the same version on every host (${tver[$tool]:-?})"; done
    fi

    if command -v lsmake >/dev/null 2>&1; then ok "lsmake is installed"
    else warn "lsmake not found: test 2 runs only the one-server side"; fi
    if remote_ok; then ok "lsmake may run tasks on other hosts for $(id -un)"
    else warn "LSF_DISABLE_LSRUN=Y and $(id -un) is not an LSF administrator: lsmake cannot use other hosts (printed p. 1878), so test 2 runs only the one-server side. Ask the LSF administrator to set LSF_DISABLE_LSRUN=N in lsf.conf (p. 1390), then run lsadmin reconfig and badmin mbdrestart (p. 804)"; fi
    if slots_capped; then ok "no host can run more job slots of queue $QUEUE than it has cores"
    else warn "on some hosts bhosts MAX is above the cores: in test 1, LSF may run more build slots on a host than it has cores. An LSF administrator can add a queue with one job slot per core: ./setup.sh queue"; fi
    mode=$(lsmake_mode)
    info "test 2 runs lsmake in $mode mode ($( [ "$mode" = batch ] && echo "bsub -K -n <cores> -m <hosts> lsmake: LSF schedules it" || echo "lsmake -m \"host cores ...\": the exact cores of each host, outside the batch queue"))"
    case "$(rsh_mode)" in
        ssh) info "CPU busy % per host: measured over ssh" ;;
        lsrun) info "CPU busy % per host: measured with lsrun" ;;
        *) info "CPU busy % per host: not measured (needs ssh without a password: ./setup.sh ssh)" ;;
    esac
    echo "Result: $npass passed, $nwarn warnings, $nfail failed"
    [ "$nfail" -eq 0 ]
}

skip2() {                              # skip2 REASON: the LSF side of test 2 is skipped; the report says why
    say "skipping the LSF side of test 2: $1"
    mkdir -p "$DIR/t2_lsf" && echo "$1" > "$DIR/t2_lsf/skipped.txt"
}

do_run() {
    do_check || die "fix the FAIL lines above, then run ./bench.sh run again"
    tmux_tip
    wait_my_jobs || die "your earlier jobs of this tool are still running: wait, or ./bench.sh clean"
    local DIR RSH h c total=0 t1 t2 d2 mode hc="" cpuh=() n
    RSH=$(rsh_mode)
    baseline
    DIR=$WORKDIR/results/$(date +%Y%m%d-%H%M%S)
    mkdir -p "$DIR" || die "cannot create $DIR"
    ln -sfn "$DIR" "$WORKDIR/results/latest"
    {
        echo "# cluster $(cluster_name)"
        for h in "${HOSTS_A[@]}"; do c=$(lsf_cpus "$h"); echo "$(short "$h") $c"; total=$((total + c)); hc="$hc $h:$c"; done
        case " ${HOSTS_A[*]} " in *" $BNAME "*|*" $BNAME."*) ;; *) echo "$BNAME $BCORES" ;; esac
    } > "$DIR/hosts.txt"
    if [ "$RSH" != none ]; then
        cpuh=(-cpu "$(awk '!/^#/ {printf "%s ", $1}' "$DIR/hosts.txt")")
    fi
    cp "$HERE/build-one.sh" "$DIR/build-one.sh" && chmod 755 "$DIR/build-one.sh" || die "cannot copy build-one.sh to $DIR"
    n=${N:-$((total / SLOTS))}
    [ "$n" -ge "$NH" ] || n=$NH
    echo
    echo "results go to $DIR"
    echo "  hosts: $NH, $total cores; baseline (one server): $BNAME, $BCORES cores"

    if [[ " $TESTS " == *" 1 "* ]]; then
        t1=$(project_for 1)
        {
            printf 'PROJECT=%q\nCONFIGURE=%q\nBUILD_DIR=%q\nMAKE_ARGS=%q\nCLEAN=%q\nSCRATCH=%q\n' \
                "$t1" "$CONFIGURE" "$BUILD_DIR" "$MAKE_ARGS" "$CLEAN" "$SCRATCH"
        } > "$DIR/t1.env"
        banner "Test 1, one server: $n clean builds of $(basename "$t1") at the same time, all on $BNAME"
        "$BF" storm -via remote -rsh "$RSH" -hosts "$BH" -script "$DIR/build-one.sh" -settings "$DIR/t1.env" \
            -src "$t1" -out "$DIR" -tag t1_ssh -n "$n" -slots "$SLOTS" "${cpuh[@]}" || say "test 1 (one server) did not complete"
        say "letting the servers settle for ${COOL}s"; sleep "$COOL"
        banner "Test 1, LSF: the same $n builds through bsub -q $QUEUE (LSF picks the hosts)"
        wait_hosts_ok 120 || say "not every host is free; the builds will wait for slots"
        "$BF" storm -via lsf -queue "$QUEUE" -hosts "${HOSTS_A[*]}" -rsh "$RSH" -script "$DIR/build-one.sh" -settings "$DIR/t1.env" \
            -src "$t1" -out "$DIR" -tag t1_lsf -n "$n" -slots "$SLOTS" "${cpuh[@]}" || say "test 1 (LSF) did not complete"
    fi

    if [[ " $TESTS " == *" 2 "* ]]; then
        [[ " $TESTS " == *" 1 "* ]] && { say "letting the servers settle for ${COOL}s"; sleep "$COOL"; }
        t2=$(project_for 2)
        d2=$t2; [ "$BUILD_DIR" = . ] || d2=$t2/${BUILD_DIR#./}
        if [ -n "$CONFIGURE" ] && [ -n "$REPO" ]; then
            banner "Test 2: configure $(basename "$t2") once (not timed)"
            echo "\$ cd $t2 && $CONFIGURE"
            if ! (cd "$t2" && eval "$CONFIGURE") > "$DIR/t2-configure.log" 2>&1; then
                tail -15 "$DIR/t2-configure.log"
                die "CONFIGURE failed (full output: $DIR/t2-configure.log)"
            fi
        fi
        banner "Test 2, one server: make -j$BCORES on $BNAME"
        "$BF" big -via remote -rsh "$RSH" -host "$BH" -j "$BCORES" -dir "$d2" -project "$t2" -clean "$CLEAN" -args "$MAKE_ARGS" \
            -out "$DIR" -tag t2_ssh "${cpuh[@]}"
        if ! command -v lsmake >/dev/null 2>&1; then
            skip2 "lsmake is not installed on this cluster"
        elif ! remote_ok; then
            skip2 "lsmake cannot use other hosts for $(id -un): LSF_DISABLE_LSRUN=Y and $(id -un) is not an LSF administrator (see ./bench.sh check)"
        else
            say "letting the servers settle for ${COOL}s"; sleep "$COOL"
            mode=$(lsmake_mode)
            banner "Test 2, LSF: the same build with lsmake on $total cores of $NH hosts ($mode mode)"
            if [ "$mode" = batch ]; then
                if wait_my_jobs && wait_hosts_ok 120; then
                    "$BF" big -via lsf -mode batch -queue "$QUEUE" -hosts "${HOSTS_A[*]}" -slots "$total" -rsh "$RSH" \
                        -dir "$d2" -project "$t2" -clean "$CLEAN" -args "$MAKE_ARGS" -out "$DIR" -tag t2_lsf "${cpuh[@]}"
                else
                    skip2 "lsmake needs all $total cores of queue $QUEUE free, and they were not"
                fi
            else
                "$BF" big -via lsf -mode direct -hosts "$hc" -rsh "$RSH" \
                    -dir "$d2" -project "$t2" -clean "$CLEAN" -args "$MAKE_ARGS" -out "$DIR" -tag t2_lsf "${cpuh[@]}"
            fi
        fi
    fi

    banner "Report"
    "$BF" report -bench "$DIR"
    echo "HTML report: $DIR/report.html"
}

case "${1:-}" in
    check) do_check ;;
    run) do_run ;;
    report)
        [ -e "$WORKDIR/results/latest" ] || die "no benchmark yet in $WORKDIR/results - run ./bench.sh run"
        exec "$BF" report -bench "$(readlink -f "$WORKDIR/results/latest")" ;;
    clean)
        ensure_lsf
        ids=$(my_jobs)
        if [ -n "$ids" ]; then
            # shellcheck disable=SC2086
            bkill $ids >/dev/null 2>&1; echo "stopped $(echo "$ids" | wc -l) job(s) of this tool"
        else
            echo "none of your jobs of this tool is in LSF"
        fi ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
