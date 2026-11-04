
#!/bin/bash

TRACE=/sys/kernel/debug/tracing
PROGRAM=/home/neemow/Desktop/HIGH_SPEED_NET_STACK/Assignment#1/LAB2/program

# 1. Stop tracing and reset settings
echo 0 > "$TRACE/tracing_on"
echo nop > "$TRACE/current_tracer"
echo > "$TRACE/trace"
echo > "$TRACE/set_event"
echo > "$TRACE/set_event_pid"
echo > "$TRACE/set_ftrace_pid"
echo > "$TRACE/set_graph_function"

# 2. Enable the events discovered using perf
echo 'sched:sched_wake_idle_without_ipi,sched:sched_stat_runtime,sched:sched_process_exec,sched:sched_waking,kmem:rss_stat,kmem:mm_page_alloc,kmem:mm_page_free_batched,kmem:mm_page_free,kmem:kmem_cache_free,kmem:kfree,kmem:kmalloc,kmem:kmem_cache_alloc,syscalls:sys_enter_mmap,syscalls:sys_exit_mmap' > "$TRACE/set_event"

# 3. Enable function graph tracing to see the call hierarchy of functions(nested do_mmap calls)
echo function_graph > "$TRACE/current_tracer"

# 4. Focus on do_mmap and its nested functions
echo do_mmap > "$TRACE/set_graph_function"

# 5. Start tracing
echo 1 > "$TRACE/tracing_on"

# 6. Launch the program with PID filtering to only trace the events related to this program.
(
    echo "$BASHPID" > "$TRACE/set_event_pid"
    echo "$BASHPID" > "$TRACE/set_ftrace_pid"
    exec "$PROGRAM"
) &

PID=$!

echo "Tracing program with PID: $PID"

# 7. Wait until the program finishes
wait "$PID"
STATUS=$?

# 8. Stop tracing
echo 0 > "$TRACE/tracing_on"

echo "Tracing finished. Exit code: $STATUS"
echo "Results are available in: $TRACE/trace"
