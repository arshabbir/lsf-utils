# shellcheck shell=bash disable=SC2034
# common.sh - settings and helpers used by bench.sh, setup.sh and steps.sh
# Author: P M Shabbir Hussain

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BF=$HERE/buildfarm

# ---------------------------------------------------------------- settings
# bench.conf (or the file in BENCH_CONF) sets them; a value given in the environment wins:
#   QUEUE=normal ./bench.sh check
CONF_KEYS="HOSTS QUEUE LSMAKE_MODE WORKDIR REPO CONFIGURE BUILD_DIR MAKE_ARGS CLEAN BASELINE_HOST N SLOTS TESTS COOL SCRATCH TOOLS PAUSE"
CONF=${BENCH_CONF:-$HERE/bench.conf}
declare -A _ENV_SET=()
for _k in $CONF_KEYS; do
    if [ -n "${!_k+x}" ]; then _ENV_SET[$_k]=${!_k}; fi
done
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi
for _k in "${!_ENV_SET[@]}"; do printf -v "$_k" '%s' "${_ENV_SET[$_k]}"; done
unset _k

HOSTS=${HOSTS:-}                     # empty: every host that is "ok" in bhosts
QUEUE=${QUEUE:-normal}
LSMAKE_MODE=${LSMAKE_MODE:-auto}     # auto | batch | direct
WORKDIR=${WORKDIR:-$HOME/lsf-build-bench-work}
REPO=${REPO:-}                       # empty: the generated sample project
CONFIGURE=${CONFIGURE:-}
BUILD_DIR=${BUILD_DIR:-.}
MAKE_ARGS=${MAKE_ARGS:-}
CLEAN=${CLEAN-make clean}            # may be set empty on purpose
BASELINE_HOST=${BASELINE_HOST:-}     # empty: the host bench.sh runs on
N=${N:-}
SLOTS=${SLOTS:-2}
TESTS=${TESTS:-1 2}
COOL=${COOL:-15}                     # seconds between the timed runs
SCRATCH=${SCRATCH:-/tmp}             # local disk on each host, for the copies of test 1
PAUSE=${PAUSE:-1}                    # steps.sh: 1 = wait for Enter after each command
if [ -z "${TOOLS:-}" ]; then
    TOOLS="gcc g++ make"
    case "$CONFIGURE" in *cmake*) TOOLS="$TOOLS cmake" ;; esac
fi

set -u
SAMPLE=$WORKDIR/sample               # the generated sample projects
SRC=$SAMPLE/app                      # small: one developer build (test 1, steps.sh)
BIG=$SAMPLE/bigapp                   # large: 121 C++ files (test 2, steps.sh)
HOSTS_A=()                           # filled by resolve_hosts
NH=0

c_cmd=$'\033[1;34m'; c_say=$'\033[0;32m'; c_bad=$'\033[1;31m'; c_off=$'\033[0m'
[ -t 1 ] || { c_cmd=; c_say=; c_bad=; c_off=; }

die()    { echo "${c_bad}ERROR: $*${c_off}" >&2; exit 1; }
say()    { echo "${c_say}# $*${c_off}"; }
banner() { printf '\n%s===== %s =====%s\n' "$c_cmd" "$*" "$c_off"; }
show() {                               # print the command, run it, show its output
    printf '\n%s$ %s%s\n' "$c_cmd" "$*" "$c_off"
    eval "$*"
    if [ "$PAUSE" = 1 ] && [ -t 0 ]; then read -r -p $'\n[Enter] ' _; fi
}
short() { echo "${1%%.*}"; }
nfiles() { find "$1" \( -name .git -o -name CMakeFiles \) -prune -o -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' \) -print 2>/dev/null | wc -l; }

ensure_lsf() {                         # works in a fresh console without profile.lsf
    command -v lsid >/dev/null 2>&1 && return 0
    local p
    for p in "${LSF_ENVDIR:-/nonexistent}/profile.lsf" /etc/profile.d/lsf.sh \
             /opt/ibm/lsfsuite/lsf/conf/profile.lsf /opt/ibm/lsf/conf/profile.lsf \
             /usr/share/lsf/conf/profile.lsf /opt/lsf/conf/profile.lsf; do
        if [ -f "$p" ]; then
            set +u
            # shellcheck disable=SC1090
            . "$p"
            set -u
            command -v lsid >/dev/null 2>&1 && return 0
        fi
    done
    die "LSF commands not found. Source your profile.lsf, then re-run."
}

# resolve_hosts: HOSTS_A = the configured hosts, or every host that is "ok" in bhosts
resolve_hosts() {
    if [ -n "$HOSTS" ]; then
        read -r -a HOSTS_A <<<"$HOSTS"
    else
        mapfile -t HOSTS_A < <(bhosts -w 2>/dev/null | awk 'NR > 1 && $2 == "ok" {print $1}')
    fi
    NH=${#HOSTS_A[@]}
    [ "$NH" -gt 0 ] || die "no hosts: set HOSTS in bench.conf, or check bhosts -w"
}

# ---------------------------------------------------------------- LSF configuration files
lsf_conf_val() {                       # last value of a parameter in lsf.conf (commented lines ignored)
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${LSF_ENVDIR:-/etc}/lsf.conf" 2>/dev/null |
        tail -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//'
}
cluster_name() { lsid 2>/dev/null | awk '/cluster name/ {print $NF}'; }

lsb_dir() {                            # LSB_CONFDIR/<cluster>/configdir
    local cd
    cd=$(lsf_conf_val LSB_CONFDIR)
    echo "${cd:-${LSF_ENVDIR:-/etc}/lsbatch}/$(cluster_name)/configdir"
}
live_dir() {                           # where bconf writes its copies, as mbatchd builds the path:
    local live a b i=0 rel           # LSF_LIVE_CONFDIR/(LSB_CONFDIR - LSF_CONFDIR)/<cluster>/configdir
    live=$(lsf_conf_val LSF_LIVE_CONFDIR)    # (lsbatch/daemons/mbd.init.c, LSB_LIVE_CONFDIR)
    [ -n "$live" ] || return 0
    a=$(lsf_conf_val LSF_CONFDIR); b=$(lsf_conf_val LSB_CONFDIR)
    if [ -n "$a" ] && [ -n "$b" ]; then
        while [ "$i" -lt "${#a}" ] && [ "${a:i:1}" = "${b:i:1}" ]; do i=$((i + 1)); done
        rel=${b:i+1}                   # mbatchd's loop also steps over the first differing character
        rel=${rel#/}
    fi
    echo "$live/${rel:-lsbatch}/$(cluster_name)/configdir"
}
# lsb_conf_file lsb.queues: the file that badmin reconfig really loads. When bconf has written
# a copy of it to LSF_LIVE_CONFDIR, LSF reads that copy instead of LSB_CONFDIR (printed p. 1908).
lsb_conf_file() {
    local live
    [ -n "$(cluster_name)" ] || return 1
    live=$(live_dir)
    if [ -n "$live" ] && [ -f "$live/$1" ]; then echo "$live/$1"; else echo "$(lsb_dir)/$1"; fi
}

# ---------------------------------------------------------------- hosts and permissions
lsf_cpus() {                           # cores LIM reports for a host (lshosts ncpus; "" if unknown)
    local c
    c=$(lshosts -w "$1" 2>/dev/null | awk 'NR == 2 {print $5}')
    case "$c" in ''|0|*[!0-9]*) c="" ;; esac
    echo "$c"
}
lsf_maxslots() {                       # job slots LSF allows on a host (bhosts MAX; "-" = unlimited)
    bhosts -w "$1" 2>/dev/null | awk 'NR == 2 {print $4}'
}
lsf_total() {                          # cores of all hosts
    local h c s=0
    for h in "${HOSTS_A[@]}"; do c=$(lsf_cpus "$h"); s=$((s + ${c:-0})); done
    echo "$s"
}
lsf_name() { bhosts -w "$1" 2>/dev/null | awk 'NR == 2 {print $1}'; }   # the name LSF uses for a host
is_lsf_admin() {                       # lsclusters -l: "LSF administrators: a b ..."
    lsclusters -l 2>/dev/null | awk -v u="$(id -un)" -F': ' '/^LSF administrators:/ {
        n = split($2, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] == u) f = 1 } END { exit !f }'
}
# remote_ok: lsrun, lsgrun and lsmake may start tasks on other hosts for this user. With
# LSF_DISABLE_LSRUN=Y (set by the installer) only LSF administrators and root may (printed p. 1878).
remote_ok() {
    case "$(lsf_conf_val LSF_DISABLE_LSRUN)" in [yY]*) is_lsf_admin || [ "$(id -u)" = 0 ] ;; *) return 0 ;; esac
}
local_host() { hostname -s; }
is_local() { [ -z "$1" ] || [ "$(short "$1")" = "$(local_host)" ]; }

# on_hosts SCRIPT TIMEOUT: run SCRIPT (a file on the shared folder) once on every host as a batch job
# (works for every user, also where lsrun is not allowed); output in SCRIPT.<host>.out
on_hosts() {
    local script=$1 limit=$2 h pids=() end
    for h in "${HOSTS_A[@]}"; do
        rm -f "$script.$(short "$h").out"
        bsub -q "$QUEUE" -m "$h" -J "bf_check_$(short "$h")" -K -o "$script.$(short "$h").out" \
            /bin/sh "$script" > "$script.$(short "$h").bsub" 2>&1 &
        pids+=($!)
    done
    end=$((SECONDS + limit))
    while [ "$SECONDS" -lt "$end" ]; do
        local running=0 p
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && running=1; done
        [ "$running" = 0 ] && break
        sleep 2
    done
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    for h in "${HOSTS_A[@]}"; do bkill -J "bf_check_$(short "$h")" >/dev/null 2>&1; done
    wait 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- the optional build queue (setup.sh)
QSIG='lsf-build-bench'                 # starts the DESCRIPTION of the queue setup.sh adds
V3DESC='C/C++ builds: least-loaded server first, at most one job slot per core'   # demo v3's queue

# queue_state: ours = setup.sh's queue is loaded; stale = an earlier version of it (lsf-build-demo);
# other = a queue the tool did not create; none = no such queue; error = bqueues failed otherwise
queue_state() {
    local out desc
    if ! out=$(LC_ALL=C bqueues -l "$QUEUE" 2>&1); then
        case "$out" in *"No such queue"*) echo none ;; *) echo error ;; esac
        return
    fi
    # bqueues -l: an empty line, "QUEUE: <name>", then "  -- <DESCRIPTION>"
    desc=$(echo "$out" | awk '/^QUEUE:/ { getline; sub(/^[[:space:]]*-- /, ""); print; exit }')
    case "$desc" in
        "$QSIG:"*) echo ours ;;
        "$V3DESC"|"lsf-build-demo v"*) echo stale ;;
        *) echo other ;;
    esac
}
limit_name() {                         # limit_name INDEX HOST: unique, at most 40 characters (p. 1701)
    local n
    n="bf_${QUEUE}_$1_$(short "$2")"
    n=$(echo "$n" | tr -c 'A-Za-z0-9_\n' '_')
    echo "${n:0:40}"
}
limit_loaded() {                       # blimits -c shows every row: right queue, host and core count
    local cfg h i=0 want
    cfg=$(LC_ALL=C blimits -c 2>/dev/null) || return 1
    for h in "${HOSTS_A[@]}"; do
        i=$((i + 1))
        want=$(lsf_cpus "$h")
        [ -n "$want" ] || return 1
        echo "$cfg" | awk -v n="$(limit_name "$i" "$h")" -v q="$QUEUE" -v host="$(lsf_name "$h")" -v s="$want" '
            $1 == "NAME" { cur = $3; next }
            cur == n && $1 == "QUEUES" { okq = ($3 == q) }
            cur == n && $1 == "HOSTS" { okh = ($3 == host) }
            cur == n && $1 == "SLOTS" { oks = ($3 == s) }
            END { exit !(okq && okh && oks) }' || return 1
    done
}
# slots_capped: queue QUEUE cannot run more job slots than cores on any host - either setup.sh's
# per-core limit is loaded, or every host allows at most its cores (bhosts MAX <= lshosts ncpus)
slots_capped() {
    limit_loaded && return 0
    local h c m
    for h in "${HOSTS_A[@]}"; do
        c=$(lsf_cpus "$h"); m=$(lsf_maxslots "$h")
        case "$m" in ''|-|*[!0-9]*) return 1 ;; esac
        [ -n "$c" ] && [ "$m" -le "$c" ] || return 1
    done
}

# lsmake_mode: batch or direct, from LSMAKE_MODE (auto = batch when no host can run more job slots than cores)
lsmake_mode() {
    case "$LSMAKE_MODE" in
        batch|direct) echo "$LSMAKE_MODE" ;;
        *) if slots_capped; then echo batch; else echo direct; fi ;;
    esac
}
lsmake_hosts() {                       # "host cores host cores ..." for lsmake -m
    local h
    for h in "${HOSTS_A[@]}"; do printf '%s %s ' "$h" "$(lsf_cpus "$h")"; done | sed 's/ $//'
}

# ---------------------------------------------------------------- ssh (optional: CPU sampling, BASELINE_HOST)
ssh_opts_init() {
    local hkc=accept-new k
    # OpenSSH older than 7.6 does not know accept-new
    ssh -G -o StrictHostKeyChecking=accept-new localhost >/dev/null 2>&1 || hkc=no
    BF_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=$hkc -o ConnectTimeout=10"
    for k in "$HOME/.ssh/id_ed25519_lsfbench" "$HOME/.ssh/id_rsa_lsfbench"; do
        if [ -f "$k" ]; then BF_SSH_OPTS="$BF_SSH_OPTS -i $k"; break; fi
    done
    export BF_SSH_OPTS
}
ssh_opts_init

ssh_host_ok() {
    # shellcheck disable=SC2086
    ssh -n $BF_SSH_OPTS "$1" true >/dev/null 2>&1
}
ssh_ok() {                             # passwordless ssh to every host?
    local h
    for h in "${HOSTS_A[@]}"; do ssh_host_ok "$h" || return 1; done
}
# rsh_mode: how buildfarm reads /proc/stat on the hosts for the CPU figures: ssh, lsrun or none
rsh_mode() {
    if ssh_ok; then echo ssh; elif remote_ok; then echo lsrun; else echo none; fi
}

ssh_key() {                            # a passphrase-less key: reuse one, or create one (never overwrites)
    local k
    local -a kt
    for k in id_ed25519 id_rsa id_ecdsa id_ed25519_lsfbench id_rsa_lsfbench; do
        k=$HOME/.ssh/$k
        if [ -f "$k" ] && [ -f "$k.pub" ] && ssh-keygen -y -P "" -f "$k" </dev/null >/dev/null 2>&1; then
            echo "$k"; return 0
        fi
    done
    for k in id_ed25519 id_rsa id_ed25519_lsfbench id_rsa_lsfbench; do
        [ -e "$HOME/.ssh/$k" ] && continue
        kt=(-t ed25519)
        case "$k" in id_rsa*) kt=(-t rsa -b 3072) ;; esac  # rsa also works where FIPS forbids ed25519
        if ssh-keygen -q "${kt[@]}" -N "" -C "$(id -un)@lsf-build-bench" -f "$HOME/.ssh/$k" </dev/null >/dev/null 2>&1; then
            echo "$HOME/.ssh/$k"; return 0
        fi
    done
    return 1
}

setup_ssh() {                          # set up passwordless ssh for this user to every host
    local key pub h fails=0 err
    command -v ssh-keygen >/dev/null 2>&1 || { echo "  ssh-keygen not found"; return 1; }
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    key=$(ssh_key) || { echo "  could not create an ssh key in $HOME/.ssh"; return 1; }
    ssh_opts_init
    pub=$(cat "$key.pub")
    echo "  using key $key (no passphrase)"
    # the home folder is shared by the hosts: adding the key here covers all of them
    mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    grep -qxF "$pub" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$pub" >> "$HOME/.ssh/authorized_keys"
    for h in "${HOSTS_A[@]}"; do
        if ssh_host_ok "$h"; then echo "  $(short "$h"): ssh works"; continue; fi
        if [ -t 0 ] && command -v ssh-copy-id >/dev/null 2>&1; then
            echo "  $(short "$h"): ssh-copy-id will ask for $(id -un)'s password once"
            ssh-copy-id -i "$key.pub" "$h" || true
        fi
        if ssh_host_ok "$h"; then continue; fi
        fails=$((fails + 1))
        # shellcheck disable=SC2086
        err=$(ssh -n $BF_SSH_OPTS "$h" true 2>&1 | tail -1)
        echo "  $(short "$h"): ssh still fails: ${err:-unknown error}"
    done
    [ "$fails" -eq 0 ] && return 0
    if [ -n "$(find "$HOME" -maxdepth 0 -perm /022 2>/dev/null)" ]; then
        echo "  hint: sshd refuses keys when the home folder is group/world-writable: chmod go-w $HOME"
    fi
    return 1
}

# ---------------------------------------------------------------- views used by steps.sh
spread() {                             # spread <job name pattern>: running builds and slots per host
    local h
    {
        for h in "${HOSTS_A[@]}"; do echo "H $(short "$h") $(lsf_cpus "$h")"; done
        # exec_host is "host:host:..." (one entry per slot), or "N*host:..." with LSB_SHORT_HOSTLIST=1
        bjobs -r -o 'job_name exec_host' -noheader 2>/dev/null | awk -v p="$1" '$1 ~ p {print "J", $2}'
    } | awk '
        $1 == "H" { order[++n] = $2; cores[$2] = $3; next }
        { k = split($2, part, ":"); seen = ""
          for (i = 1; i <= k; i++) {
              m = split(part[i], a, "*"); s = (m == 2) ? a[1] : 1; h = (m == 2) ? a[2] : a[1]
              sub(/\..*/, "", h); slots[h] += s
              if (index(seen, " " h " ") == 0) { jobs[h]++; seen = seen " " h " " }
          } }
        END { printf "  %-16s %6s %8s %11s\n", "server", "cores", "builds", "job slots"
              for (i = 1; i <= n; i++) { h = order[i]
                  printf "  %-16s %6s %8d %11d%s\n", h, cores[h], jobs[h], slots[h], (slots[h] > cores[h]) ? "   <- more slots than cores" : "" } }'
}
job_output() {                         # job_output FILE: the output of a job from its bsub -o file
    local t=0 a=-1 b                   # LSF copies the file into place shortly after bsub -K returns
    while [ "$t" -lt 60 ]; do
        b=$(wc -c < "$1" 2>/dev/null || echo -1)
        [ "$b" -gt 0 ] && [ "$b" = "$a" ] && break
        a=$b; sleep 2; t=$((t + 2))
    done
    awk 'f { print } /^The output \(if any\) follows:/ { f = 1 }' "$1" 2>/dev/null
}
lsmake_view() {                        # condense "lsmake -V -y" output for the screen
    # lsmake -V prints the hosts used: one "[host]" per slot, and "<< Execute on host H >>" per task
    awk '/^<< Execute on host / { h = $5; sub(/\..*/, "", h); if (!(h in n)) o[++k] = h; n[h]++; next }
         /^[[:space:]]*(g\+\+|c\+\+|gcc|cc|clang\+\+) / { next }
         /^(\[[^]]+\] *)+$/ { next }
         /^lsmake Summary:/ && k > 0 { printf "tasks per server:"
                                       for (i = 1; i <= k; i++) printf "  %s %d", o[i], n[o[i]]
                                       print "\n"; k = 0 }
         { print; fflush() }'
}

# ---------------------------------------------------------------- jobs of this tool
my_jobs() {                            # job IDs of your own jobs of this tool (names start with bf_)
    bjobs -o 'jobid job_name' -noheader 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^bf_/ {print $1}'
}
wait_my_jobs() {                       # until none of your bf_ jobs runs or waits (at most 5 minutes)
    local t=0 n
    while n=$(my_jobs | wc -l) && [ "$n" -gt 0 ]; do
        if [ "$t" -ge 300 ]; then
            echo; echo "${c_bad}$n of your earlier jobs of this tool are still in LSF after 5 minutes (./bench.sh clean stops them)${c_off}"
            return 1
        fi
        [ "$t" = 0 ] && printf 'waiting for your earlier jobs of this tool to finish '
        printf '.'; sleep 3; t=$((t + 3))
    done
    [ "$t" -gt 0 ] && echo
    return 0
}
pending_watch() {                      # pending_watch SECONDS: after that long, say why your job still waits
    ( sleep "$1"
      if [ "$(bjobs -p -o jobid -noheader 2>/dev/null | grep -c '^[0-9]')" -gt 0 ]; then
          echo; echo "${c_bad}# still waiting for free cores after $1 s; LSF says (bjobs -p -l):${c_off}"
          bjobs -p -l 2>/dev/null | sed -n '/PENDING REASONS/,/^ *$/p' | head -8
      fi ) &
    WATCH_PID=$!
}
wait_hosts_ok() {                      # wait_hosts_ok SECONDS: until every host is "ok" (quietly), at most SECONDS
    local end=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$end" ]; do
        hosts_ok >/dev/null && return 0
        sleep 3
    done
    hosts_ok
}
hosts_ok() {                           # every host is "ok" in bhosts (it can take jobs now)
    local h st bad=""
    for h in "${HOSTS_A[@]}"; do
        st=$(bhosts -w "$h" 2>/dev/null | awk 'NR == 2 {print $2}')
        [ "$st" = ok ] || bad="$bad $(short "$h")=${st:-unknown}"
    done
    [ -z "$bad" ] && return 0
    echo "${c_bad}not every host can take jobs now:$bad (bhosts -w)${c_off}"
    return 1
}

tmux_tip() {
    if [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ] && command -v tmux >/dev/null 2>&1; then
        say "Tip: run inside tmux so a dropped console does not stop anything: tmux new -A -s lsfbench"
    fi
    return 0
}

# ---------------------------------------------------------------- the projects to build
# project_for TEST: the source tree of test 1 or 2 - REPO, or the generated sample
project_for() {
    if [ -n "$REPO" ]; then echo "$REPO"; elif [ "$1" = 1 ]; then echo "$SRC"; else echo "$BIG"; fi
}
gen_sample() {                         # (re)generate the sample projects when missing or older
    local d
    [ -x "$BF" ] || die "the buildfarm tool is missing next to the scripts (build it: go build -o buildfarm .)"
    mkdir -p "$SAMPLE" || die "cannot create $SAMPLE"
    for d in "$SRC:8:1" "$BIG:120:2"; do
        set -- ${d//:/ }
        if grep -q "buildfarm v4" "$1/Makefile" 2>/dev/null; then continue; fi
        rm -rf "$1"
        "$BF" gen -dir "$1" -files "$2" -weight "$3" >/dev/null || die "cannot generate $1"
    done
}
