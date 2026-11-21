
#!/bin/bash

TRACE=/sys/kernel/debug/tracing
OUTPUT_DIR=/home/neemow

echo 0 > "$TRACE/tracing_on"
echo nop > "$TRACE/current_tracer"
echo > "$TRACE/trace"
echo > "$TRACE/set_event"
echo > "$TRACE/set_event_pid"
echo > "$TRACE/set_ftrace_pid"
echo netdev_tx_t > "$TRACE/set_graph_function"

echo function_graph > "$TRACE/current_tracer"

echo 1 > "$TRACE/tracing_on"

hping3 -S -p 53 --data 100 -c 5 8.8.8.8

echo 0 > "$TRACE/tracing_on"

cat "$TRACE/trace" > "$OUTPUT_DIR/ftrace_syn_all.txt"

chown neemow:neemow "$OUTPUT_DIR/ftrace_syn_all.txt"
