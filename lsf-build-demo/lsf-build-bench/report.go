// report.go - per-run summaries and the final benchmark report (text + HTML)
// Author: P M Shabbir Hussain
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type hostStat struct {
	builds   int
	busy     float64
	peak     int // most build slots running at the same time
	interval [][2]float64
}

type runStats struct {
	m                         meta
	n, ok, failed, missing    int
	makespan, avgWait, avgRun float64
	maxWait                   float64
	hosts                     map[string]*hostStat
	cpu                       map[string]float64
}

func cmdReport(args []string) error {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	out := fs.String("out", "", "output directory used by storm")
	tags := fs.String("tags", "", "comma-separated run tags to compare")
	bench := fs.String("bench", "", "benchmark directory written by bench.sh")
	fs.Parse(args)
	if *bench != "" {
		return benchReport(*bench)
	}
	if *out == "" || *tags == "" {
		return errors.New("report: -out and -tags (or -bench) are required")
	}
	return report(*out, strings.Split(*tags, ","))
}

func report(out string, tags []string) error {
	var runs []runStats
	for _, t := range tags {
		r, err := load(filepath.Join(out, strings.TrimSpace(t)))
		if err != nil {
			return err
		}
		runs = append(runs, r)
		printRun(r)
	}
	if len(runs) > 1 {
		printCompare(runs)
	}
	return nil
}

func load(runDir string) (runStats, error) {
	r := runStats{hosts: map[string]*hostStat{}}
	if err := readJSON(filepath.Join(runDir, "meta.json"), &r.m); err != nil {
		return r, fmt.Errorf("no run in %s", runDir)
	}
	var subs []submission
	if err := readJSON(filepath.Join(runDir, "submit.json"), &subs); err != nil {
		return r, fmt.Errorf("run %s never finished submitting", r.m.Tag)
	}
	r.n = len(subs)
	first, last := 0.0, 0.0
	var waitSum, runSum float64
	for _, s := range subs {
		if first == 0 || s.Submit < first {
			first = s.Submit
		}
		var res result
		if err := readJSON(filepath.Join(runDir, s.ID, "result.json"), &res); err != nil {
			r.missing++
			continue
		}
		if res.RC != 0 {
			r.failed++
		} else {
			r.ok++
		}
		wait, run := res.Start-s.Submit, res.End-res.Start
		if wait < 0 {
			wait = 0
		}
		waitSum += wait
		runSum += run
		if wait > r.maxWait {
			r.maxWait = wait
		}
		if res.End > last {
			last = res.End
		}
		h := short(res.Host)
		if r.hosts[h] == nil {
			r.hosts[h] = &hostStat{}
		}
		r.hosts[h].builds++
		r.hosts[h].busy += run
		r.hosts[h].interval = append(r.hosts[h].interval, [2]float64{res.Start, res.End})
	}
	for _, hs := range r.hosts {
		hs.peak = peakSlots(hs.interval, max(r.m.Slots, 1))
	}
	if c := r.ok + r.failed; c > 0 {
		r.avgWait, r.avgRun = waitSum/float64(c), runSum/float64(c)
		r.makespan = last - first
	}
	var w window
	if readJSON(filepath.Join(runDir, "done.json"), &w) == nil && w.End > w.Start {
		r.makespan = w.End - w.Start // driver clock: immune to clock skew between hosts
	}
	readJSON(filepath.Join(runDir, "cpu.json"), &r.cpu)
	return r, nil
}

// peakSlots: the most builds running at once on a host (from their start/end times) x slots per build.
func peakSlots(iv [][2]float64, slots int) int {
	type ev struct {
		t float64
		d int
	}
	var evs []ev
	for _, x := range iv {
		evs = append(evs, ev{x[0], 1}, ev{x[1], -1})
	}
	sort.Slice(evs, func(i, j int) bool {
		if evs[i].t != evs[j].t {
			return evs[i].t < evs[j].t
		}
		return evs[i].d < evs[j].d // an end before a start at the same instant
	})
	cur, best := 0, 0
	for _, e := range evs {
		cur += e.d
		best = max(best, cur)
	}
	return best * slots
}

// overCores: the hosts that ran more build slots at once than they have cores ("" = none).
func overCores(r runStats, hosts []hostInfo) string {
	var over []string
	for _, h := range hosts {
		if hs := r.hosts[h.name]; hs != nil && h.cores > 0 && hs.peak > h.cores {
			over = append(over, fmt.Sprintf("%s %d on %d cores", h.name, hs.peak, h.cores))
		}
	}
	return strings.Join(over, ", ")
}

// countedAll: every build has a result on one of the report's hosts (so the peak row is complete).
func countedAll(r runStats, hosts []hostInfo) bool {
	n := 0
	for _, h := range hosts {
		if hs := r.hosts[h.name]; hs != nil {
			n += hs.builds
		}
	}
	return r.missing == 0 && n == r.ok+r.failed
}

// complete: every build of the run succeeded.
func complete(r runStats) bool { return r.n > 0 && r.ok == r.n }

func describe(m meta) string {
	if m.Via == "lsf" {
		q := m.Queue
		if q == "" {
			q = "default"
		}
		return "bsub, queue " + q
	}
	if len(m.Hosts) == 1 {
		return "all on " + short(m.Hosts[0])
	}
	return fmt.Sprintf("round-robin, %d servers", len(m.Hosts))
}

func printRun(r runStats) {
	fmt.Printf("\n== run %s: %d builds x %d cores, %s\n", r.m.Tag, r.n, r.m.Slots, describe(r.m))
	fmt.Printf("   all builds finished in : %s\n", dur(r.makespan))
	fmt.Printf("   average wait to start  : %s\n", dur(r.avgWait))
	fmt.Printf("   average build time     : %s\n", dur(r.avgRun))
	fmt.Printf("   succeeded %d, failed %d, no result %d\n", r.ok, r.failed, r.missing)
	names := make([]string, 0, len(r.hosts))
	for h := range r.hosts {
		names = append(names, h)
	}
	sort.Strings(names)
	for _, h := range names {
		s := r.hosts[h]
		fmt.Printf("   %-16s %3d builds  %s\n", h, s.builds, strings.Repeat("#", s.builds*30/max(r.n, 1)))
	}
}

func printCompare(runs []runStats) {
	base := runs[0]
	fmt.Printf("\n== comparison (baseline: %s)\n", base.m.Tag)
	fmt.Printf("   %-10s %-28s %12s %10s %12s %9s\n", "run", "how", "finished in", "avg wait", "avg build", "speedup")
	for _, r := range runs {
		sp := "-"
		if r.makespan > 0 && base.makespan > 0 {
			sp = fmt.Sprintf("%.1fx", base.makespan/r.makespan)
		}
		fmt.Printf("   %-10s %-28s %12s %10s %12s %9s\n", r.m.Tag, describe(r.m), dur(r.makespan), dur(r.avgWait), dur(r.avgRun), sp)
	}
}

// ---------------------------------------------------------------- benchmark report

type hostInfo struct {
	name  string
	cores int
}

func readHosts(dir string) (cluster string, hosts []hostInfo) {
	f, err := os.Open(filepath.Join(dir, "hosts.txt"))
	if err != nil {
		return "", nil
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fl := strings.Fields(sc.Text())
		switch {
		case len(fl) >= 3 && fl[0] == "#" && fl[1] == "cluster":
			cluster = fl[2]
		case len(fl) >= 2 && fl[0] != "#":
			c, _ := strconv.Atoi(fl[1])
			hosts = append(hosts, hostInfo{short(fl[0]), c})
		}
	}
	return cluster, hosts
}

func farmCPU(cpu map[string]float64, hosts []hostInfo) (float64, bool) {
	if v, ok := cpu[keyFarm]; ok { // weighted by CPUs (cpuPct)
		return v, true
	}
	var sum float64 // reports from an older buildfarm: plain mean of the servers
	n := 0
	for _, h := range hosts {
		if v, ok := cpu[h.name]; ok {
			sum += v
			n++
		}
	}
	if n == 0 {
		return 0, false
	}
	return sum / float64(n), true
}

func pct(v float64) string { return fmt.Sprintf("%.0f%%", v) }

// table renders rows as aligned text columns.
func table(rows [][]string) string {
	w := map[int]int{}
	for _, r := range rows {
		for i, c := range r {
			w[i] = max(w[i], len(c))
		}
	}
	var b strings.Builder
	for _, r := range rows {
		b.WriteString("  ")
		for i, c := range r {
			if i == len(r)-1 {
				b.WriteString(c)
			} else {
				b.WriteString(c + strings.Repeat(" ", w[i]-len(c)+3))
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

type cpuBar struct {
	Host string
	Pct  float64
	Txt  string
}
type cpuGroup struct {
	Title string
	SSH   bool
	Bars  []cpuBar
	Avg   string
}
type htmlData struct {
	Title, Sub, Headline, T1Title, T2Title, Raw string
	T1, T2                                      [][]string
	CPU                                         []cpuGroup
	Findings                                    []string
}

func benchReport(dir string) error {
	cluster, hosts := readHosts(dir)
	if len(hosts) == 0 {
		return fmt.Errorf("no benchmark in %s (hosts.txt missing)", dir)
	}
	totalCores := 0
	for _, h := range hosts {
		totalCores += h.cores
	}
	when := time.Now()
	if st, err := os.Stat(filepath.Join(dir, "hosts.txt")); err == nil {
		when = st.ModTime()
	}

	type col struct {
		title string
		r     runStats
	}
	var cols []col
	for _, c := range []struct{ tag, title string }{
		{"t1_ssh", "one server (today)"}, {"t1_spread", "spread by hand"}, {"t1_lsf", "LSF"}} {
		if r, err := load(filepath.Join(dir, c.tag)); err == nil {
			cols = append(cols, col{c.title, r})
		}
	}
	var bigSSH, bigLSF *bigRun
	for tag, p := range map[string]**bigRun{"t2_ssh": &bigSSH, "t2_lsf": &bigLSF} {
		var b bigRun
		if readJSON(filepath.Join(dir, tag, "big.json"), &b) == nil {
			*p = &b
		}
	}

	d := htmlData{Title: "LSF build benchmark: one server versus LSF"}
	d.Sub = fmt.Sprintf("Cluster %s · %d servers · %d cores · %s · lsf-build-bench",
		orDash(cluster), len(hosts), totalCores, when.Format("2006-01-02 15:04"))
	d.Raw = dir
	var headline []string

	var t strings.Builder
	fmt.Fprintf(&t, "%s\n%s\n", d.Title, d.Sub)

	// ---- test 1
	var sshCol, spreadCol, lsfCol *col
	for i := range cols {
		switch cols[i].r.m.Tag {
		case "t1_ssh":
			sshCol = &cols[i]
		case "t1_spread":
			spreadCol = &cols[i]
		case "t1_lsf":
			lsfCol = &cols[i]
		}
	}
	if len(cols) > 0 {
		c0 := cols[0].r
		d.T1Title = fmt.Sprintf("Test 1: %d builds start at the same time (each: a clean build of %s, make -j%d)",
			c0.n, filepath.Base(c0.m.Src), c0.m.Slots)
		head, sub := []string{""}, []string{""}
		done, avg, wait, okf, farm, per := []string{"All builds done in"}, []string{"Average build time"},
			[]string{"Average wait to start"}, []string{"Builds OK / failed"}, []string{"Farm average CPU"},
			[]string{"Builds per server"}
		var coresTxt []string
		for _, h := range hosts {
			coresTxt = append(coresTxt, strconv.Itoa(h.cores))
		}
		peak := []string{"Peak build slots per server (cores " + strings.Join(coresTxt, " / ") + ")"}
		cpuRows := make([][]string, len(hosts))
		for i, h := range hosts {
			cpuRows[i] = []string{"CPU busy " + h.name}
		}
		haveCPU := false
		for _, c := range cols {
			r := c.r
			head = append(head, c.title)
			sub = append(sub, describe(r.m))
			done = append(done, dur(r.makespan))
			avg = append(avg, dur(r.avgRun))
			wait = append(wait, dur(r.avgWait))
			s := fmt.Sprintf("%d / %d", r.ok, r.failed)
			if r.missing > 0 {
				s += fmt.Sprintf(" (%d no result)", r.missing)
			}
			okf = append(okf, s)
			var counts, peaks []string
			g := cpuGroup{Title: c.title + " (" + describe(r.m) + ")", SSH: r.m.Via != "lsf"}
			for i, h := range hosts {
				n, pk := 0, 0
				if hs := r.hosts[h.name]; hs != nil {
					n, pk = hs.builds, hs.peak
				}
				counts = append(counts, strconv.Itoa(n))
				peaks = append(peaks, strconv.Itoa(pk))
				if v, ok := r.cpu[h.name]; ok {
					haveCPU = true
					cpuRows[i] = append(cpuRows[i], pct(v))
					g.Bars = append(g.Bars, cpuBar{h.name, v, pct(v)})
				} else {
					cpuRows[i] = append(cpuRows[i], "-")
				}
			}
			per = append(per, strings.Join(counts, " / "))
			peak = append(peak, strings.Join(peaks, " / "))
			if v, ok := farmCPU(r.cpu, hosts); ok {
				farm = append(farm, pct(v))
				g.Avg = pct(v)
			} else {
				farm = append(farm, "-")
			}
			if len(g.Bars) > 0 {
				d.CPU = append(d.CPU, g)
			}
		}
		d.T1 = [][]string{head, sub, done, avg, wait, okf}
		if haveCPU {
			d.T1 = append(d.T1, cpuRows...)
			d.T1 = append(d.T1, farm)
		}
		d.T1 = append(d.T1, per, peak)
		fmt.Fprintf(&t, "\n%s\n\n%s", strings.ToUpper(d.T1Title[:6])+d.T1Title[6:], table(d.T1))

		if sshCol != nil && lsfCol != nil && lsfCol.r.makespan > 0 && !(complete(sshCol.r) && complete(lsfCol.r)) {
			d.Findings = append(d.Findings, fmt.Sprintf("The two runs are not compared: builds OK on one server %d of %d, with LSF %d of %d. See build.log (and lsf.out) of each build in %s.",
				sshCol.r.ok, sshCol.r.n, lsfCol.r.ok, lsfCol.r.n, dir))
			fmt.Fprintf(&t, "\n  Result: not compared, because some builds failed or have no result.\n")
		} else if sshCol != nil && lsfCol != nil && lsfCol.r.makespan > 0 {
			sp := sshCol.r.makespan / lsfCol.r.makespan
			sshFarm, ok1 := farmCPU(sshCol.r.cpu, hosts)
			lsfFarm, ok2 := farmCPU(lsfCol.r.cpu, hosts)
			if len(sshCol.r.m.Hosts) == 1 {
				busy := short(sshCol.r.m.Hosts[0])
				f := fmt.Sprintf("On one server, all %d builds ran on %s and the other %d servers got none.",
					sshCol.r.n, busy, len(hosts)-1)
				if ok1 {
					var idle []string
					for _, h := range hosts {
						if v, ok := sshCol.r.cpu[h.name]; ok && h.name != busy {
							idle = append(idle, h.name+" "+pct(v))
						}
					}
					f += fmt.Sprintf(" CPU busy: %s %s, %s; whole farm %s.", busy, pct(sshCol.r.cpu[busy]), strings.Join(idle, ", "), pct(sshFarm))
				}
				d.Findings = append(d.Findings, f)
			}
			used := 0
			for _, h := range hosts {
				if hs := lsfCol.r.hosts[h.name]; hs != nil && hs.builds > 0 {
					used++
				}
			}
			placed := fmt.Sprintf("LSF spread the builds over %d of %d servers", used, len(hosts))
			over := overCores(lsfCol.r, hosts)
			if over == "" && countedAll(lsfCol.r, hosts) {
				placed += " and never ran more build slots on a server than it has cores (see the peak row)"
			} else if over != "" {
				placed += " (more build slots than cores at the peak on: " + over + ")"
				d.Findings = append(d.Findings, fmt.Sprintf("Queue %s lets a server run more job slots than it has cores (bhosts MAX), so LSF packed builds onto one server. Use a queue with at most one job slot per core: an LSF administrator can add one with ./setup.sh queue.", lsfCol.r.m.Queue))
			}
			cpu := ""
			if ok1 && ok2 && lsfFarm > sshFarm {
				cpu = fmt.Sprintf(" Farm CPU rose from %s to %s.", pct(sshFarm), pct(lsfFarm))
			} else if ok1 && ok2 {
				cpu = fmt.Sprintf(" Farm CPU: %s on one server, %s with LSF.", pct(sshFarm), pct(lsfFarm))
			}
			switch {
			case sp >= 1.15:
				d.Findings = append(d.Findings, fmt.Sprintf("%s: all builds finished %.1fx sooner.%s", placed, sp, cpu))
				headline = append(headline, fmt.Sprintf("%d concurrent builds: %.1fx faster with LSF", sshCol.r.n, sp))
				fmt.Fprintf(&t, "\n  Result: LSF finished all builds %.1fx faster than one server.\n", sp)
			case sp >= 0.9 && over != "":
				d.Findings = append(d.Findings, fmt.Sprintf("%s, and finished in about the same time (%.1fx).%s", placed, sp, cpu))
			case sp >= 0.9:
				d.Findings = append(d.Findings, fmt.Sprintf("%s, and finished in about the same time (%.1fx). With this few builds one server is not yet overloaded; run again with a larger N.%s", placed, sp, cpu))
				fmt.Fprintf(&t, "\n  Result: LSF and one server finished in about the same time (%.1fx).\n", sp)
			default:
				d.Findings = append(d.Findings, fmt.Sprintf("LSF was slower in this run (%.1fx). Check that nothing else was running in the queue and that the servers were idle, then run again.", sp))
				fmt.Fprintf(&t, "\n  Result: LSF was slower than one server in this run (%.1fx).\n", sp)
			}
			if lsfCol.r.avgWait >= 3 {
				d.Findings = append(d.Findings, fmt.Sprintf("An LSF build started on average %s after its bsub: the time to pick a server, plus any wait for free cores. For short compiles this matters, which is why one large build uses lsmake (test 2).", dur(lsfCol.r.avgWait)))
			}
		}
		if spreadCol != nil && lsfCol != nil && lsfCol.r.makespan > 0 {
			sp := spreadCol.r.makespan / lsfCol.r.makespan
			d.Findings = append(d.Findings, fmt.Sprintf("Spreading builds by hand (round-robin) took %s versus %s with LSF (%.1fx). That needs every developer to coordinate, and it ignores other load on the servers; LSF does it automatically, with queues, limits and accounting.",
				dur(spreadCol.r.makespan), dur(lsfCol.r.makespan), sp))
		}
	}

	// ---- test 2
	if bigSSH != nil || bigLSF != nil {
		files := 0
		for _, b := range []*bigRun{bigSSH, bigLSF} {
			if b != nil && b.Files > files {
				files = b.Files
			}
		}
		name := ""
		for _, b := range []*bigRun{bigSSH, bigLSF} {
			if b != nil && b.Project != "" {
				name = filepath.Base(b.Project)
			} else if b != nil && b.Dir != "" {
				name = filepath.Base(filepath.Clean(b.Dir))
			}
		}
		d.T2Title = fmt.Sprintf("Test 2: one large build (%s, %d C/C++ files, same Makefile, clean build)", name, files)
		d.T2 = [][]string{{"", "Command", "Time", "Farm CPU", ""}}
		row := func(label string, b *bigRun, extra string) []string {
			s := dur(b.End - b.Start)
			if b.RC != 0 {
				s += fmt.Sprintf(" (failed, exit %d)", b.RC)
			}
			fc := "-"
			if v, ok := farmCPU(b.CPU, hosts); ok {
				fc = pct(v)
			}
			return []string{label, b.Cmd, s, fc, extra}
		}
		if bigSSH != nil {
			d.T2 = append(d.T2, row(fmt.Sprintf("one server, make -j%d", bigSSH.J), bigSSH, ""))
		}
		if bigLSF != nil {
			extra := ""
			used := bigLSF.Slots // cores lsmake really got (lsmake -y), when the run recorded it
			if bigLSF.Allocated > 0 {
				used = bigLSF.Allocated
			}
			if bigSSH != nil && bigLSF.End > bigLSF.Start && bigLSF.RC == 0 && bigSSH.RC == 0 {
				sp := (bigSSH.End - bigSSH.Start) / (bigLSF.End - bigLSF.Start)
				extra = fmt.Sprintf("%.1fx", sp)
				if sp >= 1.15 {
					extra += " faster"
				}
				switch {
				case sp >= 1.15:
					d.Findings = append(d.Findings, fmt.Sprintf("lsmake split one build over %d cores of the farm%s: %.1fx faster than make -j%d on one server, with the same Makefile.", used, taskList(bigLSF.Tasks, hosts), sp, bigSSH.J))
					headline = append(headline, fmt.Sprintf("one large build: %.1fx faster with lsmake", sp))
				case sp >= 0.9:
					d.Findings = append(d.Findings, fmt.Sprintf("lsmake on %d cores took about as long as make on one server (%.1fx). Small builds gain little from spreading; check that the farm was idle.", used, sp))
				case bigSSH.End-bigSSH.Start < 20:
					d.Findings = append(d.Findings, fmt.Sprintf("This build takes only %s on one server: starting the tasks on other hosts costs more than it saves (%.1fx). lsmake pays off for builds that take minutes.", dur(bigSSH.End-bigSSH.Start), sp))
				default:
					d.Findings = append(d.Findings, fmt.Sprintf("lsmake was slower than make on one server in this run (%.1fx). Check that the farm was idle and run again.", sp))
				}
			}
			d.T2 = append(d.T2, row(fmt.Sprintf("LSF lsmake, %d cores", used), bigLSF, extra))
		} else {
			why := "lsmake did not run"
			if b, err := os.ReadFile(filepath.Join(dir, "t2_lsf", "skipped.txt")); err == nil {
				why = strings.TrimSpace(string(b))
			}
			d.Findings = append(d.Findings, "The LSF side of test 2 was skipped: "+why+".")
		}
		fmt.Fprintf(&t, "\n%s\n\n", strings.ToUpper(d.T2Title[:6])+d.T2Title[6:])
		for _, r := range d.T2[1:] {
			fmt.Fprintf(&t, "%s\n  %-34s %s\n", strings.TrimRight(fmt.Sprintf("  %-34s %-10s %s", r[0], r[2], r[4]), " "), "", r[1])
		}
	}

	shared := false
	for _, c := range cols {
		_, sk := c.r.cpu[keySharedKernel]
		shared = shared || sk
	}
	if shared {
		d.Findings = append(d.Findings, "CPU busy per server was not measured: the servers share one kernel (containers on one machine), so /proc/stat is not per server.")
	}
	d.Findings = append(d.Findings, "Every run used the same sources, build script, compiler and servers; only the way a server was chosen differs.")
	d.Headline = strings.Join(headline, " · ")
	fmt.Fprintf(&t, "\nWHAT THIS SHOWS\n")
	for _, f := range d.Findings {
		fmt.Fprintf(&t, "%s\n", wrap("  - ", f, 92))
	}
	fmt.Fprintf(&t, "\nRaw data: %s\n", dir)

	fmt.Print("\n" + t.String())
	if err := os.WriteFile(filepath.Join(dir, "report.txt"), []byte(t.String()), 0o644); err != nil {
		return err
	}
	hf, err := os.Create(filepath.Join(dir, "report.html"))
	if err != nil {
		return err
	}
	defer hf.Close()
	if err := htmlTmpl.Execute(hf, d); err != nil {
		return err
	}
	fmt.Printf("\nReport saved: %s/report.txt and report.html\n", dir)
	return nil
}

// taskList: " (compile tasks per server: a 40, b 5, c 41)" from lsmake -V, in host order.
func taskList(tasks map[string]int, hosts []hostInfo) string {
	if len(tasks) == 0 {
		return ""
	}
	var parts []string
	for _, h := range hosts {
		parts = append(parts, fmt.Sprintf("%s %d", h.name, tasks[h.name]))
	}
	return " (lsmake tasks per server: " + strings.Join(parts, ", ") + ")"
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func wrap(prefix, s string, width int) string {
	var b strings.Builder
	line := prefix
	pad := strings.Repeat(" ", len(prefix))
	for _, w := range strings.Fields(s) {
		if len(line)+len(w)+1 > width && strings.TrimSpace(line) != strings.TrimSpace(prefix) {
			b.WriteString(line + "\n")
			line = pad
		}
		if line != prefix && line != pad {
			line += " "
		}
		line += w
	}
	b.WriteString(line)
	return b.String()
}

var htmlTmpl = template.Must(template.New("r").Funcs(template.FuncMap{
	"w": func(v float64) string { return fmt.Sprintf("%.0f", min(max(v, 0), 100)) },
}).Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LSF Build Benchmark</title>
<style>
:root{--fg:#161b26;--muted:#5b6475;--line:#dde2ea;--bg:#ffffff;--soft:#f3f5f8;--ssh:#8d96a7;--lsf:#0f62fe;--good:#0e7a3a}
@media (prefers-color-scheme:dark){:root{--fg:#e8ebf1;--muted:#a3abba;--line:#323947;--bg:#14171d;--soft:#1e232c;--ssh:#7d8697;--lsf:#4589ff;--good:#42be65}}
*{box-sizing:border-box}
body{margin:0;padding:28px 16px;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif}
main{max-width:960px;margin:0 auto}
h1{font-size:26px;margin:0 0 4px}
h2{font-size:18px;margin:36px 0 10px}
.sub,.note{color:var(--muted)}
.headline{margin:18px 0 0;padding:14px 16px;border-left:4px solid var(--good);background:var(--soft);font-size:18px;font-weight:600}
.wrap{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
tr:first-child td{font-weight:600}
.t1 tr:nth-child(2) td{color:var(--muted);font-size:13px}
code{font:12px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--muted);word-break:break-all}
.groups{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px}
.group h3{font-size:14px;margin:0 0 8px}
.bar{display:grid;grid-template-columns:84px 1fr 44px;gap:8px;align-items:center;font-size:13px;margin:4px 0}
.track{height:12px;background:var(--soft);border-radius:3px;overflow:hidden}
.fill{height:100%;background:var(--lsf)} .fill.ssh{background:var(--ssh)}
ul{padding-left:20px} li{margin:6px 0}
footer{margin-top:36px;font-size:13px;color:var(--muted)}
</style></head><body><main>
<h1>{{.Title}}</h1>
<div class="sub">{{.Sub}}</div>
{{if .Headline}}<div class="headline">{{.Headline}}</div>{{end}}
{{if .T1}}<h2>{{.T1Title}}</h2>
<div class="wrap"><table class="t1">{{range .T1}}<tr>{{range .}}<td>{{.}}</td>{{end}}</tr>{{end}}</table></div>
{{if .CPU}}<h2>CPU busy on each server during test 1</h2>
<div class="groups">{{range .CPU}}<div class="group"><h3>{{.Title}}{{if .Avg}} · farm {{.Avg}}{{end}}</h3>
{{$ssh := .SSH}}{{range .Bars}}<div class="bar"><span>{{.Host}}</span><div class="track"><div class="fill{{if $ssh}} ssh{{end}}" style="width:{{w .Pct}}%"></div></div><span>{{.Txt}}</span></div>{{end}}
</div>{{end}}</div>{{end}}{{end}}
{{if .T2}}<h2>{{.T2Title}}</h2>
<div class="wrap"><table>{{range $i, $r := .T2}}<tr>{{range $j, $c := $r}}<td>{{if and (gt $i 0) (eq $j 1)}}<code>{{$c}}</code>{{else}}{{$c}}{{end}}</td>{{end}}</tr>{{end}}</table></div>{{end}}
<h2>What this shows</h2>
<ul>{{range .Findings}}<li>{{.}}</li>{{end}}</ul>
<footer>Raw data: {{.Raw}}</footer>
</main></body></html>
`))
