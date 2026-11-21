TRACE=/sys/kernel/debug/tracing

echo 0 > "$TRACE/tracing_on"
echo nop > "$TRACE/current_tracer"
echo > "$TRACE/trace"
echo > "$TRACE/set_ftrace_filter"
echo > "$TRACE/set_graph_function"

echo function_graph > "$TRACE/current_tracer"
echo dev_hard_start_xmit > "$TRACE/set_graph_function"