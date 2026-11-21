# Assignment 2 --- Measuring Packet-Processing Latency with LTTng

## 1. Introduction

The goal of this assignment is to measure and analyze packet-processing
latency within the Linux kernel using LTTng. The experiment follows a
packet through the kernel's transmit and receive paths and uses event
timestamps to measure the time between selected transmission and
reception points.

I used the loopback interface (`lo`) and generated ICMP traffic with
`ping`. LTTng was used to record networking tracepoints, and Trace
Compass was used to inspect the resulting events and correlate them
using the packet's `skbaddr`.

## 2. Identifying relevant networking events

The first step was to identify the networking events available in the
installed LTTng kernel tracer. I used:

``` bash
sudo lttng list -k | grep net
sudo lttng list -k | grep skb
```

The following four events were selected for the experiment:

  -----------------------------------------------------------------------
  Event                   Purpose                 Direction
  ----------------------- ----------------------- -----------------------
  `net_dev_queue`         Records a packet        TX
                          entering the network    
                          device's transmit       
                          queue.                  

  `net_dev_xmit`          Records the result of   TX
                          the device's transmit   
                          operation after the     
                          driver's transmit       
                          callback returns.       

  `net_if_rx`             Records a packet        RX
                          entering the receive    
                          backlog.                

  `net_if_receive_skb`    Records a packet        RX
                          entering the main       
                          kernel                  
                          receive-processing      
                          path.                   
  -----------------------------------------------------------------------

Linux defines the corresponding networking tracepoints in
`include/trace/events/net.h`. The event names exposed by LTTng can
differ from the names commonly used in Linux source-code discussions.
For example, the LTTng event used here is `net_if_receive_skb`.

![Finding available networking and skb events in
LTTng](images/find_net_skb_events.png)

*The screenshot shows the networking and skb-related kernel events
available through `lttng list -k`.*

These events provide observation points on both sides of packet
processing. The two transmit events describe the packet's progress
through the transmit path, while the receive events describe its entry
into the receive path.

## 3. Experimental setup

### 3.1 Traffic generation

I used the loopback interface (`lo`) and generated 20 ICMP echo
requests:

``` bash
ping -c 20 127.0.0.1
```

Loopback was selected to focus on packet processing inside the local
Linux networking stack without introducing an external network, router,
or remote host into the experiment.

The ping command completed successfully. Its reported round-trip-time
statistics were:

``` text
rtt min/avg/max/mdev = 0.072/0.159/0.526/0.089 ms
```

These ping statistics represent ICMP round-trip time. They are not the
same as the individual kernel processing intervals calculated from the
LTTng event timestamps.

### 3.2 Creating the LTTng session and enabling events

I created an LTTng session named `packet_proc` and enabled the four
selected kernel events:

``` bash
sudo lttng create packet_proc

sudo lttng enable-event -k net_dev_queue
sudo lttng enable-event -k net_dev_xmit
sudo lttng enable-event -k net_if_rx
sudo lttng enable-event -k net_if_receive_skb
```

LTTng confirmed that all four kernel events were created successfully in
`channel0`.

### 3.3 Starting and stopping the trace

After enabling the events, I started the session, generated the traffic,
and then stopped and destroyed the session:

``` bash
sudo lttng start packet_proc

ping -c 20 127.0.0.1

sudo lttng stop packet_proc
sudo lttng destroy packet_proc
```

The trace was initially written to:

``` text
/root/lttng-traces/packet_proc-20261121-113402
```

I changed the trace directory's ownership and moved it into my home
directory so it could be accessed more conveniently:

``` bash
sudo chown -R neemow:neemow \
    /root/lttng-traces/packet_proc-20261121-113402

sudo mkdir -p /home/neemow/lttng-traces

sudo mv /root/lttng-traces/packet_proc-20261121-113402 \
    /home/neemow/lttng-traces/
```

The resulting trace directory was:

``` text
/home/neemow/lttng-traces/packet_proc-20261121-113402
```

![LTTng session creation, event enabling, traffic generation, and trace
capture commands](images/packet_proc_trace_commands.png)

*The screenshot shows the commands used to configure the LTTng session,
generate loopback traffic, and stop the trace.*

## 4. Understanding how latency is measured

The basic idea is to correlate the same packet across the selected
events and compare their timestamps.

For one packet, the four observation points are:

1.  **`net_dev_queue` --- timestamp (T_1):** The packet enters the
    network device's transmit queue.
2.  **`net_dev_xmit` --- timestamp (T_2):** The device's transmit
    operation returns.
3.  **`net_if_rx` --- timestamp (T_3):** The packet enters the receive
    backlog.
4.  **`net_if_receive_skb` --- timestamp (T_4):** The packet enters the
    receive-processing path.

The following intervals can then be calculated:

$$
L_{\text{TX}} = T_2 - T_1
$$

$$
L_{\text{RX}} = T_4 - T_3
$$

$$
L_{\text{TX-to-RX}} = T_4 - T_1
$$

To make sure that the timestamps belong to the same packet, the events
should be correlated using the `skbaddr` field, along with the packet
metadata and event ordering.

In this experiment, all four selected events contained the same
`skbaddr`, allowing the packet to be followed across the observed
transmit and receive points.

## 5. Trace analysis

### 5.1 Identifying the same packet

In Trace Compass, I searched for the following `skbaddr`:

``` text
0xffff89177eb2ed00
```

The same address appeared in all four selected events:

-   `net_dev_queue`
-   `net_dev_xmit`
-   `net_if_rx`
-   `net_if_receive_skb`

This allows the events to be correlated as observations of the same
`sk_buff` during the captured packet path, rather than comparing
timestamps from unrelated packets.

The packet metadata also identifies the traffic as an ICMP packet on the
loopback interface:

-   Interface: `lo`
-   Protocol: ICMP
-   Source address: `127.0.0.1`
-   Destination address: `127.0.0.1`
-   IPv4 total length: 84 bytes
-   Packet address (`skbaddr`): `0xffff89177eb2ed00`

### 5.2 Reconstructing the packet's path

The relevant events and timestamps from Trace Compass are:

  -----------------------------------------------------------------------
  Event                   Timestamp               Meaning
  ----------------------- ----------------------- -----------------------
  `net_dev_queue`         `11:53:55.390078923`    Packet enters the
                                                  transmit queue

  `net_if_rx`             `11:53:55.390092151`    Packet enters the
                                                  receive backlog

  `net_dev_xmit`          `11:53:55.390106706`    Transmit operation
                                                  returns

  `net_if_receive_skb`    `11:53:55.390128630`    Packet enters receive
                                                  processing
  -----------------------------------------------------------------------

All four events have the same `skbaddr`:

``` text
0xffff89177eb2ed00
```

One notable observation is that `net_if_rx` occurs before
`net_dev_xmit`. This ordering is possible on the loopback interface
because packet reception can be processed synchronously during the
transmit operation. Therefore, the event order observed in this trace is
not necessarily the same as the order expected when considering a
physical network interface.

### 5.3 Calculating the latency

The timestamps have nanosecond precision. Using the event timestamps
above, the measured intervals are:

  ------------------------------------------------------------------------
  Measurement           Calculation                                 Result
  --------------------- --------------------- ----------------------------
  Transmit queue →      (T_3 - T_1)                              13.228 µs
  Receive backlog                             

  Transmit queue →      (T_2 - T_1)                              27.783 µs
  Transmit operation                          
  returns                                     

  Receive backlog →     (T_4 - T_3)                              36.479 µs
  Receive processing                          

  Transmit queue →      (T_4 - T_1)                              49.707 µs
  Receive processing                          
  ------------------------------------------------------------------------

The main measurement is the interval between `net_dev_queue` and
`net_if_receive_skb`:

$$
\begin{aligned}
T_1 &= 390078923\ \mathrm{ns} \\
T_4 &= 390128630\ \mathrm{ns} \\
L &= T_4 - T_1 \\
  &= 49707\ \mathrm{ns} \\
  &= \boxed{49.707\ \mu\mathrm{s}}
\end{aligned}
$$

Therefore, for this particular loopback packet, the observed interval
between entering the transmit queue and reaching the receive-processing
function was approximately **49.7 microseconds**.

This value is a specific kernel event-to-event interval. It should not
be interpreted as the complete physical transmission latency of a
network interface.

## 6. Additional observations

### 6.1 Packet correlation using `skbaddr`

All four events contain the same `skbaddr`, which makes it possible to
follow the same packet across the selected tracepoints. This is
important because comparing events from different packets would produce
an incorrect latency measurement.

The address is useful for correlating events within this captured packet
path. It should not be treated as a permanent packet identifier across
an entire trace, since kernel memory addresses can be reused.

### 6.2 Event ordering on the loopback interface

The observed order was:

``` text
net_dev_queue
net_if_rx
net_dev_xmit
net_if_receive_skb
```

The receive-backlog event appears before the transmit-operation return
event. This is consistent with the loopback interface's local
packet-delivery behavior: reception can occur synchronously while the
transmit operation is still executing.

This observation also explains why it is important to use the actual
event timestamps rather than assuming that all transmit events must
appear before all receive events.

### 6.3 Difference between packet lengths

The trace reports different packet lengths on the transmit and receive
events:

-   Transmit events (`net_dev_queue` and `net_dev_xmit`): `len = 98`
-   Receive events (`net_if_rx` and `net_if_receive_skb`): `len = 84`
-   IPv4 `tot_len`: `84`

The `len` field represents the length of the socket buffer (`skb`),
whereas IPv4 `tot_len` represents the length specified by the IPv4
header. These are different measurements. The trace shows a 14-byte
difference between the reported transmit and receive `skb` lengths;
explaining the exact point at which that difference arises would require
further inspection of the loopback transmit implementation.

## 7. RTT versus kernel packet-processing latency

The ping command reported:

``` text
rtt min/avg/max/mdev = 0.072/0.159/0.526/0.089 ms
```

The average RTT was therefore 0.159 ms, or 159 µs.

RTT and the LTTng measurement represent different intervals:

-   **RTT:** Measures the time for an ICMP echo request to reach its
    destination and for the echo reply to return.
-   **LTTng measurement:** Measures the time between two specific kernel
    tracepoints for the same packet.

The LTTng interval of 49.707 µs is not expected to equal the ping RTT.
The two measurements have different start and end points and describe
different parts of packet processing.

## 8. Conclusion

In this assignment, I used LTTng to monitor packet processing in the
Linux kernel and measure the time between selected transmit and receive
events.

First, I identified four relevant networking events: `net_dev_queue`,
`net_dev_xmit`, `net_if_rx`, and `net_if_receive_skb`. I then created an
LTTng tracing session, enabled these events, and generated ICMP traffic
using `ping` over the loopback interface.

Using Trace Compass, I identified a packet with the `skbaddr`
`0xffff89177eb2ed00` and followed it across all four events. The
timestamps showed that the interval between `net_dev_queue` and
`net_if_receive_skb` was **49.707 µs** for this packet.

The experiment also showed that `net_if_rx` can occur before
`net_dev_xmit` on the loopback interface, illustrating the synchronous
behavior of local packet delivery. Finally, comparing the LTTng result
with the ping RTT demonstrated the difference between measuring a
specific interval inside the kernel and measuring the end-to-end
round-trip time.

Overall, the experiment demonstrates how LTTng tracepoints and packet
correlation through `skbaddr` can be used to observe the Linux
networking path and quantify packet-processing intervals inside the
kernel.
