# lsf-build-bench

Benchmark C and C++ builds on an IBM Spectrum LSF cluster: **one server versus LSF**.

Author: P M Shabbir Hussain

lsf-build-bench builds your own C/C++ project (or a generated sample project) in two ways and compares them:

1. **Many builds at once.** N clean builds start at the same moment. First they all run on one server, as when a team shares one build host. Then the same N builds are submitted with `bsub`, and LSF places them on hosts with free cores.
2. **One large build.** One clean build with `make -j<cores>` on one server, then the same build with `lsmake`, LSF's parallel make, over the cores of all hosts.

At the end it prints a report and saves it as text and HTML: time until all builds finished, average build time, builds per server, peak build slots per server, CPU use, and the speed-up.

## What you need

- An IBM Spectrum LSF 10.1 cluster with two or more hosts, and an account that can submit jobs (`bsub`). You do not need to be an LSF administrator; see [Permissions](#permissions).
- A folder that every host sees at the same path, for example an NFS home folder. Your source tree must be there too.
- The same compiler and make on every host: gcc, g++ and GNU make, plus cmake if your project uses it. `./bench.sh check` compares the versions.
- Linux on x86_64 for the prebuilt `buildfarm` binary. On other platforms, build it with Go 1.21 or later (see [Files](#files)).
- bash 4 or later, GNU tar and coreutils (standard on RHEL, Rocky Linux and Ubuntu).

## Quick start: the sample project (about 5 minutes)

Log in to one of the hosts you want to use, then:

```
git clone <repository-url> lsf-build-bench
cd lsf-build-bench
. /opt/lsf/conf/profile.lsf          # your LSF profile.lsf; the scripts also try the usual places
cp bench.conf.example bench.conf
vi bench.conf                        # set HOSTS and QUEUE, see below
./bench.sh check                     # every line should say PASS; a WARN line explains a limit
./bench.sh run                       # runs both tests and prints the report
```

In `bench.conf`, set two values:

| Setting | What to put there |
|---|---|
| `HOSTS` | Two or more LSF host names from `lshosts -w`, for example `HOSTS="host1 host2 host3"`. Empty means every host that is `ok` in `bhosts`. |
| `QUEUE` | A queue you can submit jobs to (`bqueues`). The queue `normal` that LSF installs works. |

The host you run `bench.sh` on is the "one server" side of the comparison, so run it on one of `HOSTS`. To use another host for that side, set `BASELINE_HOST`; that needs ssh without a password (`./setup.sh ssh`).

The report is printed at the end and saved as `report.txt` and `report.html` in `WORKDIR/results/<date-time>/`. `WORKDIR` is `$HOME/lsf-build-bench-work` unless you change it. `./bench.sh report` prints the last report again.

Run long benchmarks inside `tmux` or `screen`, so a dropped connection does not stop them.

## Benchmark your own C/C++ project

1. Put the source tree on the shared folder, for example `git clone <your-repo> $HOME/repos/myproject`.
2. Set `REPO` in `bench.conf`. For CMake or autotools, also set `CONFIGURE`, and `BUILD_DIR` if the build happens in a subfolder.
3. Run `./bench.sh check`, then `./bench.sh run`.

Examples (the first two were run with this version):

```
# A plain Makefile (Lua 5.4.6 release tarball)
REPO="$HOME/repos/lua-5.4.6"

# CMake (yaml-cpp); use the "Unix Makefiles" generator
REPO="$HOME/repos/yaml-cpp"
CONFIGURE='cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DYAML_CPP_BUILD_TESTS=OFF'
BUILD_DIR="build"

# autotools: the same pattern, not part of the tests of this version
REPO="$HOME/repos/myproject"
CONFIGURE="./configure"
```

The other settings: `MAKE_ARGS` holds targets or variables for make, for example `"all"`. `CLEAN` is the command that cleans the build folder before every timed build, and defaults to `make clean`.

Notes:

- The project must build with make. `lsmake` is a modified GNU Make that supports GNU Make 3.81 (IBM Spectrum LSF 10.1.0 documentation, printed pp. 1382-1383). CMake's "Unix Makefiles" generator worked in the tests above.
- Test 2 shows a speed-up only for builds that take a while on one server. In the tests above, Lua (1 second on 16 cores) and yaml-cpp (4 seconds) got no faster with lsmake, and the sample project (35 seconds) got 1.7 to 1.9 times faster. Test 1 sped up all three.

## What the tests do

**Test 1: N builds at the same time.** `N` defaults to the cores of all `HOSTS` divided by `SLOTS` (2), so the builds fill the farm once.

- One server: N copies of `build-one.sh` run at the same time on the baseline host. Each one copies the project to local disk (`SCRATCH`, default `/tmp`), leaving out `.git` and `BUILD_DIR`. It then runs `CONFIGURE` in the copy, `CLEAN`, and `make -j$SLOTS $MAKE_ARGS`.
- LSF: the same N builds, each submitted as
  `bsub -q $QUEUE -m "$HOSTS" -n $SLOTS -R "span[hosts=1]" build-one.sh ...`.
  LSF chooses the host for each build.

**Test 2: one large build.** `CONFIGURE` runs once in `REPO` and is not timed. Each timed build first runs `CLEAN` in `REPO/BUILD_DIR`.

- One server: `make -j<cores of the baseline host> $MAKE_ARGS`.
- LSF: `lsmake -V -y $MAKE_ARGS` on all cores of `HOSTS`, in one of two modes (`LSMAKE_MODE`):
  - `batch`: `bsub -K -n <cores> -q $QUEUE -m "$HOSTS" lsmake ...`. LSF schedules and records the job. `-K` waits for the job, and bsub exits with the job's exit code (printed p. 1307); unlike `-I`, it also works in queues that do not accept interactive jobs, such as the installed queue `normal`.
  - `direct`: `lsmake -m "host1 cores host2 cores ..."`, which uses exactly the cores of each host.
  - `auto` (the default) uses `batch` when no host can run more job slots than it has cores, and `direct` otherwise (see [Hosts with more job slots than cores](#hosts-with-more-job-slots-than-cores)).

All results are kept in `WORKDIR/results/<date-time>/`:

- `hosts.txt`
- for test 1, in `t1_*/b*/`: `result.json`, `build.log` and `lsf.out` for every build
- for test 2, in `t2_*/`: `big.json` and `build.log` (and `lsmake.out` in batch mode)
- `report.txt` and `report.html`

## Reading the report

- **All builds done in**: from the first submission until the last build finished, measured on the host that runs `bench.sh`.
- **Average wait to start**: from submission until the build started. It uses the hosts' own clocks, so keep them in sync with NTP.
- **Peak build slots per server**: the most build slots that ran at the same time on each server, next to its cores.
- **Speed-up**: one-server time divided by LSF time. The report gives a speed-up only when every build on both sides succeeded; otherwise it says why it does not compare the runs.
- **CPU busy**: measured from `/proc/stat` on each host, and for the farm weighted by each host's CPUs. It needs ssh without a password to the hosts (`./setup.sh ssh`) or permission to use `lsrun`; otherwise it is left out. When the hosts are containers on one machine, they share one `/proc/stat`, and the report says so instead of showing numbers.

Both sides use the same sources, compiler, flags and hosts; only the way a server is chosen differs. The one-server side of test 1 is a team sharing one build host. It is not the best possible manual distribution. Other work on the hosts changes the results, so run the benchmark more than once.

## Permissions

| What | Who can run it |
|---|---|
| `./bench.sh check`, test 1, the one-server side of test 2 | Any user who can submit jobs |
| The LSF side of test 2 (`lsmake` on other hosts), `lsrun` in `steps.sh` | LSF administrators and root, unless `LSF_DISABLE_LSRUN` is turned off |
| `./setup.sh queue` and `./setup.sh remove` | LSF administrators |

The LSF installer sets `LSF_DISABLE_LSRUN=Y`. With that setting, RES refuses `lsrun`, `lsgrun` and `lsmake` tasks from other hosts unless the user is an LSF administrator or root (printed p. 1878). `./bench.sh check` tells you which applies to you, and `./bench.sh run` then skips the LSF side of test 2 and says why. To let every user run lsmake on other hosts, an LSF administrator sets `LSF_DISABLE_LSRUN=N` in `lsf.conf` (printed p. 1390), then runs `lsadmin reconfig` and `badmin mbdrestart` (printed p. 804).

## Hosts with more job slots than cores

Some clusters let a host run more job slots than it has cores (`bhosts` MAX above `lshosts` ncpus). On such a queue, LSF can place several builds on one host beyond its cores. `./bench.sh check` warns about this, and the report shows it in the peak row.

An LSF administrator can add a queue that allows at most one job slot per core on each of `HOSTS`:

```
./setup.sh queue          # adds the queue "build"; ./setup.sh queue NAME for another name
```

Then set `QUEUE="build"` in `bench.conf`. `./setup.sh remove` takes the queue out again.

What `setup.sh queue` does:

- It adds the queue to `lsb.queues`, with `HOSTS` set to your hosts.
- It adds a Limit section to `lsb.resources`, with one row per host and that host's core count (printed pp. 1695-1696).
- When `bconf` has been used on the cluster, it edits the copies in `LSF_LIVE_CONFDIR`, which LSF loads instead of the normal files (printed p. 1908).
- It backs up every file it changes, puts them all back if any step fails, and checks after `badmin reconfig` that LSF loaded both the queue and the limit.
- It refuses to touch a queue with the same name that it did not create.

It does not use `PJOB_LIMIT`. With `PARALLEL_SCHED_BY_SLOT=Y`, which the installer sets in `lsb.params`, LSF counts every job slot as a processor, so "one job slot per processor" follows MXJ instead of the cores.

## Optional: a guided tour

`./steps.sh all` walks through LSF with the sample project in six steps:

1. the hosts LSF sees
2. one compile, on this host and on the host LSF picks
3. one build as a batch job
4. many builds at once, and how LSF spreads them
5. one large build with lsmake
6. accounting

Each command is printed before it runs. It waits for Enter after each command; `PAUSE=0 ./steps.sh all` runs without stopping.

## Troubleshooting

| Message | What to do |
|---|---|
| `queue X does not exist` | Set `QUEUE` to a queue from `bqueues`. |
| `the check job did not run within 3 minutes` | The queue is busy or the host is closed: `bhosts -w`, `bjobs -p`. |
| `does not see .../lsf-build-bench-work` | `WORKDIR` must be on a folder that every host sees at the same path. |
| `does not see the project` | Put `REPO` on the shared folder. |
| `different versions on the hosts of: ...` | Install the same toolchain on every host. |
| `lsmake cannot use other hosts` | See [Permissions](#permissions). |
| `more build slots than cores` | See [Hosts with more job slots than cores](#hosts-with-more-job-slots-than-cores). |
| a build failed | Read `build.log` in the result folder. For test 2, lsmake needs a Makefile that GNU Make 3.81 can run. |
| jobs left over after an interrupted run | `./bench.sh clean` stops your jobs of this tool (job names start with `bf_`). |

## Files

| File | Contents |
|---|---|
| `bench.sh` | `check`, `run`, `report`, `clean` |
| `bench.conf.example` | All settings, with examples. Copy it to `bench.conf`. |
| `build-one.sh` | One clean build, used by test 1 |
| `setup.sh` | Optional: `queue`, `remove` (LSF administrator) and `ssh` |
| `steps.sh` | Optional guided tour |
| `common.sh` | Settings and helpers used by the scripts |
| `buildfarm` | Prebuilt static Linux x86_64 binary: starts the builds and writes the report |
| `main.go`, `gen.go`, `run.go`, `report.go`, `go.mod` | Source of `buildfarm`, Go standard library only. Rebuild with `CGO_ENABLED=0 go build -o buildfarm .` |
| `lsb.queues.demo`, `lsb.resources.demo` | What `setup.sh queue` adds, for reference |

The scripts write only in `WORKDIR`, in `SCRATCH` (temporary copies, removed after each build), and in the generated sample project and the `CLEAN` step of your build folder. They stop only your own jobs whose names start with `bf_`. `setup.sh` changes the LSF configuration only when an administrator runs `queue` or `remove`.

## Tested with

- IBM Spectrum LSF Standard 10.1.0.16 on three Rocky Linux 8 hosts with 16, 2 and 16 cores
- gcc and g++ 8.5, GNU Make 4.2.1, CMake 3.26
- the configuration as LSF installs it, and a configuration where hosts allow 5000 job slots and `bconf` copies are in `LSF_LIVE_CONFDIR`
- as an LSF administrator and as an ordinary user
- the sample project, Lua 5.4.6 (Makefile) and yaml-cpp (CMake)
