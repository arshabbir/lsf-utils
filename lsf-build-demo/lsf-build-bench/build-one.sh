#!/bin/bash
# build-one.sh SETTINGS OUTDIR JOBS - one clean build of a project (bench.sh test 1).
# Copies the project to local disk (SCRATCH), runs CONFIGURE there (when set), cleans, runs
# make -jJOBS in BUILD_DIR and writes OUTDIR/result.json. Runs as an LSF job, or on the baseline
# host. SETTINGS is a file written by bench.sh: PROJECT CONFIGURE BUILD_DIR MAKE_ARGS CLEAN SCRATCH.
# Author: P M Shabbir Hussain
set -u
SETTINGS=$1
OUT=$2
J=${3:-${LSB_DJOB_NUMPROC:-2}}       # under LSF: the cores allocated by bsub -n
# shellcheck disable=SC1090
. "$SETTINGS"
mkdir -p "$OUT" || exit 1
START=$(date +%s.%N)
RC=0
WS=$(mktemp -d "${SCRATCH:-/tmp}/lsfbench.XXXXXX") || { echo "cannot create a folder in ${SCRATCH:-/tmp}" > "$OUT/build.log"; RC=1; }
if [ "$RC" -eq 0 ]; then
    # the copy leaves out .git and an out-of-source build folder (it holds paths of the original)
    excl=(--exclude=./.git)
    if [ "$BUILD_DIR" != "." ]; then excl+=("--exclude=./${BUILD_DIR#./}"); fi
    (cd "$PROJECT" && tar "${excl[@]}" -cf - .) | (cd "$WS" && tar -xf -) || RC=$?
fi
if [ "$RC" -eq 0 ] && [ -n "$CONFIGURE" ]; then
    (cd "$WS" && eval "$CONFIGURE") > "$OUT/configure.log" 2>&1 || RC=$?
fi
if [ "$RC" -eq 0 ]; then
    (
        cd "$WS/$BUILD_DIR" || exit 1
        if [ -n "$CLEAN" ]; then eval "$CLEAN" >/dev/null 2>&1; fi
        eval "make -j$J $MAKE_ARGS"
    ) > "$OUT/build.log" 2>&1 || RC=$?
fi
END=$(date +%s.%N)
printf '{"host":"%s","jobid":"%s","slots":%s,"start":%s,"end":%s,"rc":%d}\n' \
    "$(hostname -s)" "${LSB_JOBID:-0}" "$J" "$START" "$END" "$RC" > "$OUT/result.json.tmp"
mv "$OUT/result.json.tmp" "$OUT/result.json"
[ -n "${WS:-}" ] && cd / && rm -rf "$WS"
exit "$RC"
