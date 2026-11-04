# Lab Report: Tracing the Linux Scheduler with LTTng and Trace Compass

## Table of Contents

1. [Objective](#1-objective)
2. [Environment](#2-environment)
3. [Tracing Setup](#3-tracing-setup)
4. [Running the Workload](#4-running-the-workload)
5. [Analysis in Trace Compass](#5-analysis-in-trace-compass)
6. [How the Linux Scheduler Works](#6-how-the-linux-scheduler-works)
7. [State Transitions Observed](#7-state-transitions-observed)
8. [Patterns Identified](#8-patterns-identified)
9. [Issues Encountered](#9-issues-encountered)
10. [Conclusion](#10-conclusion)

---

## 1. Objective

Use **stress-ng** to load a few CPU cores with matrix multiplication, trace the system with **LTTng**, and analyze the result in **Trace Compass**. The trace must include:

- **Events:** `sched_switch`, all `sched_wak*` events, interrupts, `sched_process_fork`, `sched_process_exit`
- **Contexts:** Virtual Process ID (`vpid`), Virtual Thread ID (`vtid`), Process Name (`procname`), Priority (`prio`)

Then explain how the scheduler works, observe state transitions, and identify patterns.

## 2. Environment

| Item          | Value                                   |
| ------------- | --------------------------------------- |
| OS            | Ubuntu (Linux)                          |
| Tracer        | LTTng 2.13 (kernel tracing)             |
| Analysis tool | Trace Compass                           |
| Workload      | `stress-ng --matrix`                    |
| CPUs          | 12 logical CPUs (CPU 0 – CPU 11, as shown in the Resources view) |
| Workers used  | 4 matrix workers                        |

---

## 3. Tracing Setup

The tracing session was created with the following commands:

```shell
sudo lttng create stress_test
sudo lttng enable-event -k sched_switch,irq_'*',sched_wak*,softirq_'*',sched_process_fork,sched_process_exit
sudo lttng add-context -k -t procname -t vtid -t vpid -t prio
sudo lttng start
```

![LTTng session setup](images/create_event_context.png)

| Command | Purpose |
| --- | --- |
| `lttng create stress_test` | Creates a session named `stress_test`. The trace is written to `/root/lttng-traces/stress_test-<date>-<time>` (root-owned because `sudo` was used). |
| `enable-event -k ...` | Enables the required **kernel** events (see table below). |
| `add-context -k ...` | Attaches extra information to every event. |
| `lttng start` | Begins recording. |

**Events enabled**

| Event | Meaning |
| --- | --- |
| `sched_switch` | The CPU switches from one task to another (context switch). |
| `sched_wak*` (`sched_waking`, `sched_wakeup`, `sched_wakeup_new`) | A task is woken up and placed on a run queue. |
| `irq_*` | Hardware interrupt entry/exit (`irq_handler_entry`, `irq_handler_exit`). |
| `softirq_*` | Software interrupt raise/entry/exit (timer, RCU, scheduler, ...). |
| `sched_process_fork` | A new process/thread is created. |
| `sched_process_exit` | A process/thread terminates. |

**Contexts added**

| Context | Meaning |
| --- | --- |
| `procname` | Name of the running process (e.g. `stress-ng`, `swapper/2`). |
| `vpid` | Process ID as seen inside its PID namespace. |
| `vtid` | Thread ID as seen inside its PID namespace. |
| `prio` | Scheduling priority of the task. |

---

## 4. Running the Workload

```shell
sudo stress-ng --matrix 4 --matrix-size 128 --timeout 10s
sudo lttng stop
sudo lttng destroy
```

![Running stress-ng](images/run_stress_ng.png)

| Option | Meaning |
| --- | --- |
| `--matrix 4` | Starts **4 workers** that repeatedly perform matrix operations (CPU-bound). |
| `--matrix-size 128` | Each matrix is 128 × 128. |
| `--timeout 10s` | Stops after 10 seconds. |

stress-ng confirmed `dispatching hogs: 4 matrix` and a successful run in `10.00s`. After the run, the session was stopped (`lttng stop`, which flushes the buffers) and destroyed (`lttng destroy`; the recorded trace stays on disk). The trace folder was then imported into Trace Compass (*Right click → Tracing → Trace Import*), after making sure the current user had read access to it.

---

## 5. Analysis in Trace Compass

### 5.1 Control Flow view

The Control Flow view shows the state of every process/thread over time.

![Control Flow view](images/control_flow_view.png)

What can be read from it (default Trace Compass colors: **green** = running in user mode, **yellow** = blocked/waiting, **grey** = not existing / unknown):

- **Process tree:** `bash (7880)` → `sudo (14685)` → `sudo (14686)` → `stress-ng (14687)`. The last one is the stress-ng **parent**, which created four **worker threads/processes: 14688, 14689, 14690, 14691** (all with parent TID 14687).
- **Creation time:** all four workers were born within about half a millisecond of each other at `17:07:10.58` (see the *Birth time* column), which matches the `sched_process_fork` events.
- **Parent and sudo are yellow:** `sudo`, the second `sudo` and the stress-ng parent are almost entirely **blocked/waiting** during the run. They are only waiting for their children to finish and do not use CPU.
- **Workers are solid green:** the four workers are in **user mode for almost the entire 10 seconds**, i.e. they are pure CPU-bound computation.
- **Other processes are mostly yellow:** background tasks such as `systemd-journal`, `systemd-logind`, `rsyslog` threads, `pipewire` and kernel threads (`migration/8`, `ksoftirqd/2`) are asleep most of the time and wake up briefly.
- **Histogram (bottom):** shows the number of events over time. The trace has a gap between roughly `17:06:23` and `17:06:55`, which is the period when the session was stopped (see [Issues Encountered](#9-issues-encountered)). The event rate stays high during the stress test period.

The tooltip in the screenshot also shows that a single state interval can be extremely short (a 402 ns interval on CPU 0), which gives an idea of how fine-grained the scheduler activity is.

### 5.2 Resources view

The Resources view shows, for each **CPU**, which thread is running (the *Threads* row) and the CPU state (the *States* row), plus the IRQs.

![Resources view](images/resources_view1.png)

Observations:

- The stress-ng workers appear on several CPUs (labels such as `stress-ng (14690)` and `stress-ng (14691)` are visible on CPU 2 and CPU 5). **4 workers occupy 4 CPUs' worth of time**, while the other CPUs stay mostly idle (thin lines with short activity).
- The **States** rows of busy CPUs are **green** (user mode) for the entire stress period.
- Some CPUs, such as CPU 0, 1, 2, 3 and 5, show the workload being **split into segments with different labels**: the scheduler moved threads between CPUs (migration) or interrupted them for other tasks.
- On **CPU 6 and CPU 7** a single thread (same orange color) runs on CPU 6, then continues on **CPU 7** for a few seconds, and then returns to **CPU 6**. This is a clear example of a **thread migration** between CPUs. The regular pill-shaped segmentation on CPU 6 shows the thread being interrupted at regular intervals.
- **CPU 11** is occupied by a single long bar for almost the whole run: a worker stayed on this CPU without being moved.
- The thin vertical colored lines on the idle CPUs are short bursts of activity: interrupts, kernel threads and background processes.
- The IRQ rows at the bottom (`IRQ 126/xhci_hcd`, `IRQ 137/nvme0q1`) show hardware interrupts from the USB controller and the NVMe disk.

### 5.3 Event table

Selecting a region and opening the event table shows the raw events together with the contexts we added.

![Event table with contexts](images/resources_view2.png)

Example events from the screenshot:

| Event | Details |
| --- | --- |
| `irq_softirq_entry` / `irq_softirq_exit` | `vec=7, name=SCHED` on CPU 2 and CPU 1: the **scheduler softirq** (periodic load balancing). |
| `irq_softirq_raise` | `vec=9, name=RCU`, raised by `stress-ng` (`vtid=14689`, `vpid=14689`) on CPU 0. |
| Context fields | `context._procname="swapper/2"`, `_vtid=0`, `_vpid=0`, `_prio=20`: this is the **idle task** of CPU 2. For stress-ng: `_procname="stress-ng"`, `_vtid=14689`, `_prio=20`. |

This confirms that the four contexts requested in the assignment (`procname`, `vtid`, `vpid`, `prio`) are attached to every event. All shown tasks have `prio = 20`, which is the **default priority** of a normal (non-real-time) task, i.e. nice value 0. Since LTTng reports the priority relative to the real-time range, a lower number means a higher priority, and no real-time tasks appear in this part of the trace.

---

## 6. How the Linux Scheduler Works

The Linux scheduler decides **which runnable task runs on which CPU, and for how long**. The main ideas:

1. **One run queue per CPU.** Each CPU has its own queue of runnable tasks. This avoids lock contention and keeps tasks close to their cache.
2. **Fair scheduling for normal tasks.** Normal tasks (`SCHED_OTHER`) are scheduled by the fair scheduler (CFS, and EEVDF in newer kernels). Each task accumulates *virtual runtime* while it runs, and the task that has received the **least CPU time relative to its weight** is chosen next. This gives every task a fair share. Priority (nice value) only changes the weight of that share.
3. **Time slices and preemption.** A running task is not allowed to monopolize the CPU when others are waiting. The periodic **timer tick** checks whether the current task has used its share, and if so it is **preempted** and a `sched_switch` occurs. A newly woken task can also preempt the current one.
4. **Real-time policies** (`SCHED_FIFO`, `SCHED_RR`, `SCHED_DEADLINE`) always have priority over normal tasks.
5. **Blocking and waking.** A task that waits for something (I/O, a timer, a child process, a lock) leaves the run queue and sleeps. When the event occurs, another task or an interrupt handler **wakes it up** (`sched_waking` → `sched_wakeup`) and it is put back on a run queue.
6. **Load balancing.** Periodically (triggered by the `SCHED` softirq seen in the trace) and when a CPU becomes idle, the scheduler moves tasks from busy CPUs to idle ones. This is why threads migrate between CPUs.
7. **Idle task.** If a CPU has nothing to run, it runs its `swapper/N` idle task (seen in the trace with `vtid = 0`).

---

## 7. State Transitions Observed

A task goes through the following states, each tied to specific trace events:

```
            sched_process_fork
                   │
                   ▼
   ┌──────────► Runnable (waiting for CPU) ◄─────────────┐
   │                │                                    │
   │        sched_switch (task chosen)           sched_wakeup
   │                ▼                                    │
   │            Running ─── sched_switch (blocks) ──► Blocked / sleeping
   │                │
   │   sched_switch (preempted, still runnable)
   └────────────────┤
                    │ exit
                    ▼
            sched_process_exit
```

| Transition | Event(s) | Where it was seen |
| --- | --- | --- |
| **Creation** | `sched_process_fork`, then `sched_wakeup_new` | The stress-ng parent (14687) created workers 14688–14691 at `17:07:10.58`. |
| **Runnable → Running** | `sched_switch` (task is the *next* task) | Workers get a CPU and turn green almost immediately. |
| **Running → Runnable (preemption)** | `sched_switch` with the task still runnable | Workers being interrupted by other tasks and timer ticks; bars split into segments. |
| **Running → Blocked** | `sched_switch` (task goes to sleep) | `sudo` and the stress-ng parent wait for their children and stay yellow. |
| **Blocked → Runnable** | `sched_waking`, `sched_wakeup` | Background processes (journal, pipewire, kernel threads) wake up briefly, run, and sleep again. |
| **Migration** | `sched_switch` on a different CPU | A thread moves between CPU 6 and CPU 7 in the Resources view. |
| **Termination** | `sched_process_exit` | Workers and stress-ng parent end at about `17:07:20`, 10 seconds after they started. |
| **Idle** | `sched_switch` to `swapper/N` | The idle CPUs run `swapper` when nothing else is runnable. |

---

## 8. Patterns Identified

- **CPU-bound workers behave very differently from interactive/background tasks.** The matrix workers never block voluntarily, so they stay running (green) for the entire 10 s. Background tasks run for microseconds to milliseconds and then sleep.
- **The parent is idle while the workers run.** `sudo` and the stress-ng parent are blocked in a wait state and consume no CPU.
- **4 workers use about 4 CPUs.** The scheduler spreads the CPU-bound workers over different CPUs rather than stacking them on one, so they run **in parallel** and don't compete with each other. The other 8 CPUs remain mostly idle.
- **Workers are mostly stable, but sometimes migrate.** Some workers stay on one CPU for a long time (for example the long bars on CPU 5 and CPU 11), but others move between CPUs (CPU 6 ↔ CPU 7), because of load balancing and wake-up placement decisions.
- **Priority is the same for all tasks seen** (`prio = 20`), so fairness is decided by virtual runtime, not by priority.
- **Interrupt and softirq activity is periodic.** The `SCHED` and `RCU` softirqs, timer interrupts and device IRQs (NVMe, USB) appear as thin vertical lines across all CPUs. They briefly interrupt the running task and then return to it.
- **Short interruptions on busy CPUs.** Busy CPUs show regular small gaps in the thread bar: these are the points where timer ticks, interrupts or other short tasks briefly run before the worker continues.

---

## 9. Issues Encountered

| Problem | Cause | Fix |
| --- | --- | --- |
| `bash: number: No such file or directory` | The command was run with the literal text `<number of cores>`. The shell treats `<` as input redirection. | Replace the placeholder with a real number: `--matrix 4`. |
| `No stress workers invoked` | `stress-ng` was run without any stressor option. | Run `stress-ng --matrix 4 ...`. |
| Gap in the trace histogram (about 17:06:23 – 17:06:55) | The session was stopped (`lttng stop`) after the failed attempts and started again before the real run. | No effect on the analysis: the stress test itself (`17:07:10` – `17:07:20`) is fully captured. |
| Trace not found in the home directory | The session was created with `sudo`, so the trace was written to `/root/lttng-traces/...`. | Use the path printed by `lttng create`, and make it readable by your user (e.g. `sudo chown -R $USER <trace_dir>`) before importing it into Trace Compass. |

---

## 10. Conclusion

- LTTng with the selected events and contexts gives a complete view of what the scheduler does: every context switch, wake-up, fork, exit and interrupt is recorded with the process name, PID/TID and priority.
- Running `stress-ng --matrix 4` created 4 CPU-bound workers that were scheduled **in parallel on separate CPUs**, remained in user mode for the whole 10-second run, and ended together, while their parent processes (`sudo`, `stress-ng`) just waited.
- The scheduler's behavior is visible in the trace: **per-CPU run queues, fair sharing, preemption by ticks and short tasks, wake-ups of sleeping tasks, periodic load balancing (`SCHED` softirq), thread migration, and idle tasks** (`swapper`).
- Trace Compass makes this easy to analyze: the **Control Flow** view shows the life and state of each thread, the **Resources** view shows how CPUs were used, and the **event table** exposes the raw events with their contexts.
