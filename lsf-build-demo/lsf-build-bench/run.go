// run.go - starts the builds: many at once (storm) or one large build (big)
// Author: P M Shabbir Hussain
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type meta struct {
	Tag    string   `json:"tag"`
	Src    string   `json:"src"`
	Via    string   `json:"via"` // lsf | remote
	Rsh    string   `json:"rsh"` // ssh | lsrun (remote runs and CPU sampling)
	Queue  string   `json:"queue,omitempty"`
	Hosts  []string `json:"hosts,omitempty"` // remote: the fixed hosts ("local" = this host); lsf: bsub -m
	N      int      `json:"n"`
	Slots  int      `json:"slots"`
	Broken int      `json:"broken,omitempty"`
}

type submission struct {
	ID     string  `json:"id"`
	JobID  string  `json:"jobid"`
	Submit float64 `json:"submit"`
}

type result struct {
	Host  string  `json:"host"`
	JobID string  `json:"jobid"`
	Slots int     `json:"slots"`
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	RC    int     `json:"rc"`
}

// window is measured on the driver's clock: first submit until all builds finished.
type window struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
}

var jobIDRe = regexp.MustCompile(`Job <([0-9]+)>`)

// ---------------------------------------------------------------- storm

func cmdStorm(args []string) error {
	fs := flag.NewFlagSet("storm", flag.ExitOnError)
	m := meta{}
	fs.StringVar(&m.Src, "src", "", "project directory (shared path)")
	script := fs.String("script", "", "build script, run as: SCRIPT ARG OUTDIR SLOTS (default: SRC/build.sh with ARG = SRC)")
	settings := fs.String("settings", "", "ARG for -script (a settings file); default SRC")
	out := fs.String("out", "", "shared output directory")
	fs.StringVar(&m.Tag, "tag", "run", "name of this run")
	fs.IntVar(&m.N, "n", 12, "number of builds started at the same time (developers)")
	fs.IntVar(&m.Slots, "slots", 2, "cores per build (bsub -n / make -j)")
	fs.StringVar(&m.Via, "via", "lsf", "lsf = bsub; remote = ssh/lsrun to fixed hosts")
	fs.StringVar(&m.Queue, "queue", "", "LSF queue (bsub -q)")
	hosts := fs.String("hosts", "", "remote: hosts to use, round-robin (one host = everyone on the same server; local = this host); lsf: the hosts LSF may use (bsub -m)")
	fs.StringVar(&m.Rsh, "rsh", "ssh", "remote command and CPU sampling: ssh, lsrun or none")
	fs.IntVar(&m.Broken, "broken", 0, "make the first K builds fail to compile")
	cpuHosts := fs.String("cpu", "", "measure CPU busy % on these hosts during the run")
	noWait := fs.Bool("nowait", false, "lsf: submit and exit without waiting")
	timeout := fs.Duration("timeout", 60*time.Minute, "give up waiting after this long")
	fs.Parse(args)

	m.Hosts = strings.Fields(*hosts)
	execHosts := append([]string(nil), m.Hosts...)
	for i, h := range m.Hosts { // the report names the real host
		if h == "local" {
			m.Hosts[i] = localName()
		}
	}
	switch {
	case m.Src == "" || *out == "":
		return errors.New("storm: -src and -out are required")
	case m.Via != "lsf" && m.Via != "remote":
		return errors.New("storm: -via must be lsf or remote")
	case m.Via == "remote" && len(m.Hosts) == 0:
		return errors.New("storm: -via remote needs -hosts")
	case m.Via == "remote" && *noWait:
		return errors.New("storm: -nowait works only with -via lsf")
	}
	build, arg := *script, *settings
	if build == "" {
		build = filepath.Join(m.Src, "build.sh")
	}
	if arg == "" {
		arg = m.Src
	}
	if _, err := os.Stat(build); err != nil {
		return fmt.Errorf("storm: %s not found", build)
	}
	runDir := filepath.Join(*out, m.Tag)
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		return err
	}
	for _, f := range []string{"submit.json", "done.json", "cpu.json"} {
		os.Remove(filepath.Join(runDir, f))
	}
	writeJSON(filepath.Join(runDir, "meta.json"), m)

	cpuH := strings.Fields(*cpuHosts)
	var cpu0 map[string]cpuStat
	if len(cpuH) > 0 {
		cpu0 = readCPU(m.Rsh, cpuH)
	}

	var (
		subs   []submission
		wg     sync.WaitGroup
		mu     sync.Mutex
		exited = map[string]bool{}
	)
	start := now()
	for i := 1; i <= m.N; i++ {
		id := fmt.Sprintf("b%03d", i)
		bdir := filepath.Join(runDir, id)
		os.RemoveAll(bdir)
		os.MkdirAll(bdir, 0o755)
		broken := i <= m.Broken
		s := submission{ID: id, Submit: now()}

		if m.Via == "lsf" {
			a := []string{"-J", "bf_" + m.Tag + "_" + id, "-n", strconv.Itoa(m.Slots),
				"-R", "span[hosts=1]", "-o", filepath.Join(bdir, "lsf.out")}
			if m.Queue != "" {
				a = append(a, "-q", m.Queue)
			}
			if len(m.Hosts) > 0 {
				a = append(a, "-m", strings.Join(m.Hosts, " "))
			}
			a = append(a, build, arg, bdir, strconv.Itoa(m.Slots))
			env := ""
			cmd := exec.Command("bsub", a...)
			cmd.Env = os.Environ()
			if broken {
				env = "BROKEN=1 "
				cmd.Env = append(cmd.Env, "BROKEN=1")
			}
			outb, err := cmd.CombinedOutput()
			if i <= 2 || err != nil { // the first commands in full; the rest are the same apart from the name
				fmt.Printf("$ %s%s\n", env, showCmd("bsub", a))
				fmt.Printf("  %s\n", strings.TrimSpace(string(outb)))
			} else if i == 3 {
				fmt.Printf("$ ... the same bsub for b003 to b%03d\n", m.N)
			}
			if err != nil {
				return fmt.Errorf("bsub failed for %s: %v", id, err)
			}
			if mm := jobIDRe.FindSubmatch(outb); mm != nil {
				s.JobID = string(mm[1])
			}
		} else {
			h := execHosts[(i-1)%len(execHosts)]
			command := fmt.Sprintf("%s %s %s %d", build, arg, bdir, m.Slots)
			if broken {
				command = "BROKEN=1 " + command
			}
			if i <= 2 {
				fmt.Printf("$ %s\n", rshShow(m.Rsh, h, command))
			} else if i == 3 {
				fmt.Printf("$ ... the same for b003 to b%03d\n", m.N)
			}
			wg.Add(1)
			go func(id, h, command, bdir string) {
				defer wg.Done()
				runRemote(m.Rsh, h, command, bdir)
				mu.Lock()
				exited[id] = true
				mu.Unlock()
			}(id, h, command, bdir)
			time.Sleep(100 * time.Millisecond) // developers do not all press Enter in the same millisecond
		}
		subs = append(subs, s)
	}
	writeJSON(filepath.Join(runDir, "submit.json"), subs)
	if *noWait {
		first, last := subs[0].JobID, subs[len(subs)-1].JobID
		fmt.Printf("submitted %d builds (jobs %s to %s)\n", len(subs), first, last)
		return nil
	}

	fmt.Printf("waiting for %d builds to finish ...\n", len(subs))
	t0, last, lastPrint := time.Now(), -1, time.Now()
	for {
		done := 0
		for _, s := range subs {
			mu.Lock()
			ex := exited[s.ID]
			mu.Unlock()
			if ex || finished(filepath.Join(runDir, s.ID)) {
				done++
			}
		}
		if done != last || time.Since(lastPrint) > 15*time.Second {
			fmt.Printf("  %4.0fs  %d of %d finished\n", time.Since(t0).Seconds(), done, len(subs))
			last, lastPrint = done, time.Now()
		}
		if done == len(subs) {
			break
		}
		if time.Since(t0) > *timeout {
			return fmt.Errorf("timeout after %s; check: bjobs -w", *timeout)
		}
		time.Sleep(time.Second)
	}
	end := now()
	wg.Wait()
	writeJSON(filepath.Join(runDir, "done.json"), window{Start: start, End: end})
	if cpu0 != nil {
		writeJSON(filepath.Join(runDir, "cpu.json"), cpuPct(cpu0, readCPU(m.Rsh, cpuH)))
	}
	return report(*out, []string{m.Tag})
}

// runRemote runs one build over ssh/lsrun; retries only if the connection itself failed.
func runRemote(rsh, host, command, bdir string) {
	logf, err := os.Create(filepath.Join(bdir, "remote.out"))
	if err != nil {
		return
	}
	defer logf.Close()
	for attempt := 1; attempt <= 3; attempt++ {
		cmd := rshCmd(rsh, host, command)
		cmd.Stdout, cmd.Stderr = logf, logf
		err := cmd.Run()
		if _, e := os.Stat(filepath.Join(bdir, "result.json")); e == nil {
			return
		}
		var ee *exec.ExitError
		if rsh == "ssh" && errors.As(err, &ee) && ee.ExitCode() == 255 && attempt < 3 {
			fmt.Fprintf(logf, "[buildfarm] ssh connection failed, retry %d\n", attempt)
			time.Sleep(time.Duration(attempt) * time.Second)
			continue
		}
		fmt.Printf("  ! %s on %s did not finish: see %s\n", filepath.Base(bdir), short(host), logf.Name())
		return
	}
}

// waitStable: wait until a file exists and its size has not changed for 2 seconds (at most limit).
func waitStable(path string, limit time.Duration) {
	end := time.Now().Add(limit)
	last, same := int64(-1), 0
	for time.Now().Before(end) {
		if st, err := os.Stat(path); err == nil {
			if st.Size() == last && st.Size() > 0 {
				same++
				if same >= 4 {
					return
				}
			} else {
				last, same = st.Size(), 0
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// jobStat: the state of an LSF job (PEND, RUN, DONE, EXIT ...), "" if bjobs cannot tell.
func jobStat(id string) string {
	out, err := exec.Command("bjobs", "-o", "stat", "-noheader", id).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// countSources: C and C++ source files under dir (.git left out).
func countSources(dir string) int {
	n := 0
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() && (d.Name() == ".git" || d.Name() == "CMakeFiles") { // CMakeFiles: CMake's own probe sources
			return filepath.SkipDir
		}
		switch strings.ToLower(filepath.Ext(p)) {
		case ".c", ".cc", ".cpp", ".cxx":
			n++
		}
		return nil
	})
	return n
}

// pendingReasons: the PENDING REASONS lines of "bjobs -p -l".
func pendingReasons(out string) []string {
	var r []string
	in := false
	for _, l := range strings.Split(out, "\n") {
		t := strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(t, "PENDING REASONS"):
			in = true
		case in && t == "":
			return r
		case in:
			r = append(r, t)
		}
	}
	return r
}

// finished: build.sh wrote result.json, or LSF wrote its job report (job died early).
func finished(bdir string) bool {
	if _, err := os.Stat(filepath.Join(bdir, "result.json")); err == nil {
		return true
	}
	b, err := os.ReadFile(filepath.Join(bdir, "lsf.out"))
	return err == nil && strings.Contains(string(b), "Resource usage summary")
}

// ---------------------------------------------------------------- big

type bigRun struct {
	Tag     string             `json:"tag"`
	Via     string             `json:"via"`
	Host    string             `json:"host,omitempty"`
	Queue   string             `json:"queue,omitempty"`
	Mode    string             `json:"mode,omitempty"` // lsf: batch (bsub -K lsmake) or direct (lsmake -m)
	J       int                `json:"j,omitempty"`
	Slots   int                `json:"slots,omitempty"`
	Dir     string             `json:"dir"`
	Project string             `json:"project,omitempty"`
	Files   int                `json:"files"`
	Cmd     string             `json:"cmd"`
	Start   float64            `json:"start"`
	End     float64            `json:"end"`
	RC      int                `json:"rc"`
	CPU     map[string]float64 `json:"cpu,omitempty"`
	// lsf: what LSF really gave the build (lsmake -y summary) and the compile tasks per server (lsmake -V)
	Allocated int            `json:"allocated,omitempty"`
	Tasks     map[string]int `json:"tasks,omitempty"`
}

var (
	execLine  = regexp.MustCompile(`^<< Execute on host (\S+) >>`)
	totalLine = regexp.MustCompile(`Total Slots Allocated:\s*([0-9]+)`)
)

func cmdBig(args []string) error {
	fs := flag.NewFlagSet("big", flag.ExitOnError)
	b := bigRun{}
	dir := fs.String("dir", "", "project directory on the shared path")
	out := fs.String("out", "", "shared output directory")
	fs.StringVar(&b.Tag, "tag", "big", "name of this run")
	fs.StringVar(&b.Via, "via", "lsf", "lsf = lsmake on the farm; remote = make on one host")
	rsh := fs.String("rsh", "ssh", "remote command and CPU sampling: ssh, lsrun or none")
	fs.StringVar(&b.Host, "host", "", "remote: the server to build on (local = this host)")
	fs.IntVar(&b.J, "j", 8, "remote: make -j")
	fs.StringVar(&b.Queue, "queue", "", "lsf, batch mode: queue")
	fs.IntVar(&b.Slots, "slots", 8, "lsf, batch mode: cores for lsmake (bsub -n)")
	fs.StringVar(&b.Mode, "mode", "batch", "lsf: batch = bsub -K -n SLOTS lsmake; direct = lsmake -m \"host cores ...\"")
	lsfHosts := fs.String("hosts", "", "lsf: batch = the hosts LSF may use (bsub -m); direct = \"host:cores host:cores ...\"")
	clean := fs.String("clean", "make clean", "command run in -dir before the build (empty = none)")
	makeArgs := fs.String("args", "", "make / lsmake arguments and targets")
	project := fs.String("project", "", "the project's top folder, for its name and file count (default: -dir)")
	cpuHosts := fs.String("cpu", "", "measure CPU busy % on these hosts during the run")
	maxWait := fs.Duration("maxwait", 15*time.Minute, "lsf: kill the job if it has not started after this long")
	fs.Parse(args)
	if *dir == "" || *out == "" || (b.Via == "remote" && b.Host == "") {
		return errors.New("big: -dir, -out (and -host for -via remote) are required")
	}
	runDir := filepath.Join(*out, b.Tag)
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		return err
	}
	os.Remove(filepath.Join(runDir, "big.json"))
	*dir = filepath.Clean(*dir)
	b.Dir = *dir
	if *project == "" {
		*project = *dir
	}
	b.Project = filepath.Clean(*project)
	b.Files = countSources(b.Project)

	if strings.TrimSpace(*clean) != "" { // every build starts from a clean tree (the tree is shared)
		fmt.Printf("$ cd %s && %s\n", *dir, *clean)
		c := exec.Command("/bin/sh", "-c", *clean)
		c.Dir = *dir
		c.Run()
	}

	var cmd *exec.Cmd
	jobOut := ""
	switch b.Via {
	case "remote":
		command := fmt.Sprintf("cd %s && make -j%d %s", *dir, b.J, *makeArgs)
		cmd = rshCmd(*rsh, b.Host, command)
		b.Cmd = rshShow(*rsh, b.Host, strings.TrimSpace(command))
		b.Slots, b.Mode = 0, ""
		if b.Host == "local" {
			b.Host = localName()
		}
	case "lsf":
		margs := strings.Fields(*makeArgs)
		switch b.Mode {
		case "batch":
			// -K: wait for the job; unlike -I it also works in queues with INTERACTIVE = NO (the
			// installed queue "normal"). lsmake's output goes to jobOut, read after the job ends.
			jobOut = filepath.Join(runDir, "lsmake.out")
			os.Remove(jobOut)
			a := []string{"-K", "-n", strconv.Itoa(b.Slots), "-o", jobOut}
			if b.Queue != "" {
				a = append(a, "-q", b.Queue)
			}
			if h := strings.Fields(*lsfHosts); len(h) > 0 {
				a = append(a, "-m", strings.Join(h, " "))
			}
			a = append(a, "lsmake", "-V", "-y")
			a = append(a, margs...)
			cmd = exec.Command("bsub", a...)
			b.Cmd = "cd " + *dir + " && " + showCmd("bsub", a)
		case "direct":
			var list []string
			b.Slots = 0
			for _, hc := range strings.Fields(*lsfHosts) {
				h, c, ok := strings.Cut(hc, ":")
				n, err := strconv.Atoi(c)
				if !ok || err != nil || n < 1 {
					return fmt.Errorf("big: -hosts for -mode direct is \"host:cores ...\", got %q", hc)
				}
				list = append(list, h, c)
				b.Slots += n
			}
			if len(list) == 0 {
				return errors.New("big: -mode direct needs -hosts \"host:cores ...\"")
			}
			a := append([]string{"-m", strings.Join(list, " "), "-V", "-y"}, margs...)
			cmd = exec.Command("lsmake", a...)
			b.Cmd = "cd " + *dir + " && " + showCmd("lsmake", a)
			b.Queue = ""
		default:
			return errors.New("big: -mode must be batch or direct")
		}
		cmd.Dir = *dir
		b.J, b.Host = 0, ""
	default:
		return errors.New("big: -via must be lsf or remote")
	}
	fmt.Printf("$ %s\n", b.Cmd)

	cpuH := strings.Fields(*cpuHosts)
	var cpu0 map[string]cpuStat
	if len(cpuH) > 0 {
		cpu0 = readCPU(*rsh, cpuH)
	}
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr = pw, pw
	hidden := 0
	var (
		mu        sync.Mutex
		jobID     string
		tail      []string
		inSummary bool
	)
	logf, err := os.Create(filepath.Join(runDir, "build.log"))
	if err != nil {
		return err
	}
	defer logf.Close()
	tasks := map[string]int{}
	var order []string
	scanDone := make(chan struct{})
	// handle: one line of make / lsmake / bsub output; everything goes to the log, the screen gets
	// the LSF lines and lsmake's summary
	handle := func(line string) {
		if m := jobIDRe.FindStringSubmatch(line); m != nil && b.Via == "lsf" {
			mu.Lock()
			jobID = m[1]
			mu.Unlock()
		}
		fmt.Fprintln(logf, line)
		tail = append(tail, line)
		if len(tail) > 20 {
			tail = tail[1:]
		}
		if m := execLine.FindStringSubmatch(line); m != nil {
			h := short(m[1])
			if tasks[h] == 0 {
				order = append(order, h)
			}
			tasks[h]++
			return
		}
		if m := totalLine.FindStringSubmatch(line); m != nil {
			b.Allocated, _ = strconv.Atoi(m[1])
		}
		switch {
		case strings.HasPrefix(line, "lsmake Summary:"):
			if len(order) > 0 {
				var parts []string
				for _, h := range order {
					parts = append(parts, fmt.Sprintf("%s %d", h, tasks[h]))
				}
				fmt.Println("  lsmake tasks per server: " + strings.Join(parts, ", "))
			}
			inSummary = true
			fmt.Println("  " + line)
		case inSummary && strings.TrimSpace(line) != "":
			fmt.Println("  " + line)
		case inSummary:
			inSummary = false
		case strings.HasPrefix(line, "<<"):
			fmt.Println("  " + line)
		default:
			hidden++
		}
	}
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			handle(sc.Text())
		}
		close(scanDone)
	}()
	b.Start = now()
	if err := cmd.Start(); err != nil {
		return err
	}
	if b.Via == "lsf" && b.Mode == "batch" { // an exact bsub -n waits until every slot is free: say why, never hang
		watch := time.AfterFunc(60*time.Second, func() {
			mu.Lock()
			id := jobID
			mu.Unlock()
			if id != "" && jobStat(id) == "PEND" {
				out, _ := exec.Command("bjobs", "-p", "-l", id).CombinedOutput()
				fmt.Printf("  ! job %s still waits for %d free cores after 60s; LSF says:\n", id, b.Slots)
				for _, l := range pendingReasons(string(out)) {
					fmt.Println("    " + l)
				}
			}
		})
		defer watch.Stop()
		limit := time.AfterFunc(*maxWait, func() {
			mu.Lock()
			id := jobID
			mu.Unlock()
			if id != "" && jobStat(id) == "PEND" {
				fmt.Printf("  ! job %s did not start within %s: bkill %s\n", id, *maxWait, id)
				exec.Command("bkill", id).Run()
			}
		})
		defer limit.Stop()
	}
	err = cmd.Wait()
	b.End = now()
	pw.Close()
	<-scanDone
	if jobOut != "" { // the job's output: the lines after LSF's "The output (if any) follows:"
		// LSF copies the output file into place shortly after bsub -K returns
		waitStable(jobOut, 60*time.Second)
		if data, rerr := os.ReadFile(jobOut); rerr == nil {
			lines := strings.Split(string(data), "\n")
			for i, l := range lines {
				if strings.HasPrefix(l, "The output (if any) follows:") {
					lines = lines[i+1:]
					break
				}
			}
			for _, l := range lines {
				handle(l)
			}
		}
	}
	if hidden > 0 {
		fmt.Printf("  (%d lines of build output not shown: %s)\n", hidden, logf.Name())
	}
	if len(tasks) > 0 {
		b.Tasks = tasks
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		b.RC = ee.ExitCode()
	} else if err != nil {
		b.RC = -1
	}
	if cpu0 != nil {
		b.CPU = cpuPct(cpu0, readCPU(*rsh, cpuH))
	}
	writeJSON(filepath.Join(runDir, "big.json"), b)
	if b.RC != 0 {
		fmt.Printf("  the build failed; its last lines (full output: %s):\n", logf.Name())
		for _, l := range tail {
			fmt.Println("    " + l)
		}
	}
	fmt.Printf("   took %s (exit code %d)\n", dur(b.End-b.Start), b.RC)
	return nil
}
