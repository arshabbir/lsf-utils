// buildfarm - the build runner and report writer of lsf-build-bench (IBM Spectrum LSF)
//
// Author: P M Shabbir Hussain
//
//	buildfarm gen    -dir DIR                       generate a sample C++ project, Makefile and build.sh
//	buildfarm storm  -via lsf|remote ...            start N builds at once (bsub, or on fixed hosts)
//	buildfarm big    -via lsf|remote ...            one large build (lsmake on the farm, or make on one host)
//	buildfarm report -out DIR -tags a,b             compare storm runs
//	buildfarm report -bench DIR                     final benchmark report (report.txt + report.html)
//
// Standard library only. Build: CGO_ENABLED=0 go build -o buildfarm .
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "gen":
		err = cmdGen(os.Args[2:])
	case "storm":
		err = cmdStorm(os.Args[2:])
	case "big":
		err = cmdBig(os.Args[2:])
	case "report":
		err = cmdReport(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "buildfarm:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `usage:
  buildfarm gen    -dir DIR [-files 120] [-weight 4]
  buildfarm storm  -src DIR -out DIR -tag NAME [-n 12] [-slots 2] [-script FILE -settings FILE]
                   -via lsf    [-queue Q] [-hosts "h1 h2 ..."] [-nowait]       (bsub -n SLOTS for each build)
                   -via remote -hosts "local | h1 [h2 ...]" [-rsh ssh|lsrun]    (builds on fixed hosts)
                   [-cpu "h1 h2 h3"]
  buildfarm big    -dir DIR -out DIR -tag NAME [-clean CMD] [-args MAKEARGS] [-cpu "h1 h2 h3"]
                   -via lsf    -mode batch  -queue Q -slots N [-hosts "h1 h2"]  (bsub -K -n N lsmake)
                   -via lsf    -mode direct -hosts "h1:cores h2:cores ..."     (lsmake -m "h1 cores ...")
                   -via remote -host local|H -j N [-rsh ssh|lsrun]              (make -jN on one host)
  buildfarm report -out DIR -tags NAME[,NAME...]
  buildfarm report -bench DIR
`)
}

// ---------------------------------------------------------------- remote execution

// rshCmd runs a shell command on a fixed host, the way developers do today ("local" = this host).
func rshCmd(rsh, host, command string) *exec.Cmd {
	if host == "local" {
		return exec.Command("/bin/sh", "-c", command)
	}
	if rsh == "lsrun" {
		return exec.Command("lsrun", "-m", host, "/bin/sh", "-c", command)
	}
	// BF_SSH_OPTS is set by common.sh (it knows the OpenSSH version and which key to use)
	opts := strings.Fields(os.Getenv("BF_SSH_OPTS"))
	if len(opts) == 0 {
		opts = []string{"-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"}
	}
	args := append([]string{"-n"}, opts...)
	return exec.Command("ssh", append(args, host, command)...)
}

func rshShow(rsh, host, command string) string {
	if host == "local" {
		return command
	}
	if rsh == "lsrun" {
		return fmt.Sprintf("lsrun -m %s sh -c '%s'", host, command)
	}
	return fmt.Sprintf("ssh %s '%s'", host, command)
}

// ---------------------------------------------------------------- CPU sampling

type cpuStat struct{ busy, total uint64 }

// Keys of a CPU map that are not hosts.
const (
	keyFarm         = "_farm"          // all servers together, weighted by their CPUs
	keySharedKernel = "_shared_kernel" // the hosts share one kernel: no per-server CPU
)

// readCPU reads the first line of /proc/stat on every host, in parallel. When two hosts report
// the same kernel boot_id (containers on one machine), /proc/stat is the whole machine's, not
// the server's: it then returns only the keySharedKernel entry.
func readCPU(rsh string, hosts []string) map[string]cpuStat {
	out := map[string]cpuStat{}
	boot := map[string]string{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, h := range hosts {
		wg.Add(1)
		go func(h string) {
			defer wg.Done()
			b, err := rshCmd(rsh, h, "head -1 /proc/stat; cat /proc/sys/kernel/random/boot_id").Output()
			if err != nil {
				return
			}
			lines := strings.SplitN(strings.TrimSpace(string(b)), "\n", 2)
			f := strings.Fields(lines[0])
			if len(f) < 9 || f[0] != "cpu" {
				return
			}
			if len(lines) == 2 {
				mu.Lock()
				boot[h] = strings.TrimSpace(lines[1])
				mu.Unlock()
			}
			var v [8]uint64
			var total uint64
			for i := 0; i < 8; i++ { // user nice system idle iowait irq softirq steal
				v[i], _ = strconv.ParseUint(f[i+1], 10, 64)
				total += v[i]
			}
			mu.Lock()
			out[h] = cpuStat{busy: total - v[3] - v[4], total: total}
			mu.Unlock()
		}(h)
	}
	wg.Wait()
	seen := map[string]bool{}
	for _, id := range boot {
		if id != "" && seen[id] {
			return map[string]cpuStat{keySharedKernel: {}}
		}
		seen[id] = true
	}
	return out
}

// cpuPct: per-host CPU busy % between two samples, keyed by short host name, plus keyFarm: the
// busy time of all hosts over their total time, so a 16-core server weighs 8 times a 2-core one.
func cpuPct(a, b map[string]cpuStat) map[string]float64 {
	_, sa := a[keySharedKernel]
	_, sb := b[keySharedKernel]
	if sa || sb {
		return map[string]float64{keySharedKernel: 1}
	}
	pct := map[string]float64{}
	var busy, total uint64
	for h, s0 := range a {
		s1, ok := b[h]
		if !ok || s1.total <= s0.total {
			continue
		}
		pct[short(h)] = 100 * float64(s1.busy-s0.busy) / float64(s1.total-s0.total)
		busy += s1.busy - s0.busy
		total += s1.total - s0.total
	}
	if total > 0 {
		pct[keyFarm] = 100 * float64(busy) / float64(total)
	}
	return pct
}

// ---------------------------------------------------------------- helpers

func short(h string) string { return strings.SplitN(h, ".", 2)[0] }

// localName: the short name of this host.
func localName() string {
	h, _ := os.Hostname()
	return short(h)
}

func now() float64 { return float64(time.Now().UnixNano()) / 1e9 }

func dur(sec float64) string {
	if sec <= 0 {
		return "0s"
	}
	d := (time.Duration(sec*1000) * time.Millisecond).Round(time.Second)
	if d < time.Second {
		return "<1s"
	}
	return d.String()
}

func writeJSON(path string, v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	os.WriteFile(path, b, 0o644)
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// quote shows an argument the way you would type it in a shell.
func quote(a string) string {
	if a == "" || strings.ContainsAny(a, " \t\"'[]()*$;&|<>") {
		return "'" + a + "'"
	}
	return a
}

func showCmd(name string, args []string) string {
	q := make([]string, len(args))
	for i, a := range args {
		q[i] = quote(a)
	}
	return name + " " + strings.Join(q, " ")
}
