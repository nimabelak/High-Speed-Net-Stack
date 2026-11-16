# Assignment 1 — Understanding `struct net_device`

## 1. Introduction

`struct net_device` is a central data structure in the Linux kernel networking subsystem. It represents a network interface and stores the state, configuration, queues, statistics, and operation callbacks associated with that interface.

The structure acts as a common representation of network devices inside the kernel. Networking code can use this representation without needing to know every hardware-specific detail of an individual network interface.

This report examines the definition of `struct net_device` in the Linux source code, summarizes its main groups of fields, and identifies the role of its operations table. The final part of the assignment—observing nested function calls with `ftrace`—will be added after the tracing experiment.

## 2. Locating the structure definition

The definition was located in the Linux kernel source tree in the `netdevice.h` header file:

```c
struct net_device {
    ...
};
```

The structure is large and contains fields for several parts of the networking subsystem. It is not simply a collection of device identity and hardware settings: it also contains information used by the transmit and receive paths, queue management, protocol integration, statistics, synchronization, and device lifecycle management.

The source comments also refer to the kernel documentation file:

```text
Documentation/networking/net_cachelines/net_device.rst
```

This documentation describes the cache-line organization of `struct net_device`. The comments in the header indicate that the layout is deliberately organized with frequently accessed fields grouped together.

## 3. Examining the structure

The definition contains many fields, so it is useful to understand them by their purpose rather than treating the structure as one flat list.

### 3.1 Transmit-path fields

The first cache-line group is marked:

```c
__cacheline_group_begin(net_device_read_tx);
```

It contains fields that are frequently read on the transmit path. Examples include:

| Field | Purpose |
|---|---|
| `netdev_ops` | Pointer to the network device's operations table |
| `header_ops` | Pointer to operations related to link-layer headers |
| `_tx` | Pointer to the device's transmit queues |
| `real_num_tx_queues` | Number of transmit queues currently in use |
| `gso_max_size` | Maximum supported Generic Segmentation Offload size |
| `gso_max_segs` | Maximum number of segments for GSO |
| `mtu` | Maximum Transmission Unit configured for the interface |
| `needed_headroom` | Additional headroom required before packet data |

The presence of queue, segmentation, and MTU fields in this group shows that `struct net_device` stores information needed when preparing and transmitting packets.

### 3.2 Fields shared by transmit and receive paths

The next group is marked:

```c
__cacheline_group_begin(net_device_read_txrx);
```

It includes:

- Per-CPU statistics pointers such as `lstats`, `tstats`, and `dstats`.
- `state`, which stores device state information.
- `flags`, which stores network-interface flags.
- `hard_header_len`, which describes the link-layer header length.
- `features`, which describes supported networking features.
- `ip6_ptr`, which points to IPv6-related device information.

These fields are relevant to both transmit and receive processing. The per-CPU statistics pointers are particularly notable: they allow statistics to be maintained per CPU rather than requiring every update to use a single shared counter.

### 3.3 Receive-path fields

The receive-oriented cache-line group begins with:

```c
__cacheline_group_begin(net_device_read_rx);
```

Some of its fields are:

| Field | Purpose |
|---|---|
| `xdp_prog` | Associated eXpress Data Path program |
| `ifindex` | Network interface index |
| `real_num_rx_queues` | Number of receive queues currently in use |
| `_rx` | Pointer to receive queues |
| `gro_max_size` | Maximum Generic Receive Offload size |
| `rx_handler` | Receive-handler callback |
| `rx_handler_data` | Data associated with the receive handler |
| `nd_net` | Network namespace association |

These fields support packet reception, receive-queue management, and receive-side processing features such as XDP and GRO.

### 3.4 Interface identity and hardware-related information

The structure also stores the interface name and several hardware-related fields:

```c
char name[IFNAMSIZ];

unsigned long mem_end;
unsigned long mem_start;
unsigned long base_addr;
```

Other interface-address fields include:

- `perm_addr`: permanent hardware address.
- `dev_addr`: pointer to the current device address.
- `addr_len`: length of the interface address.
- `broadcast`: broadcast address.
- `type`: hardware/interface type.

The structure therefore contains both identifying information and fields used to describe the device's hardware-facing characteristics.

### 3.5 Queues, scheduling, and packet-processing configuration

The structure includes several queue-related fields, such as:

```c
struct netdev_queue *_tx;
struct netdev_rx_queue *_rx;
struct Qdisc __rcu *qdisc;
unsigned int tx_queue_len;
unsigned int num_tx_queues;
unsigned int num_rx_queues;
```

These fields connect the network device to its transmit and receive queues and to queueing discipline (qdisc) functionality.

The structure also contains configuration for traffic classes, queue mappings, GSO/TSO, GRO, and other packet-processing features. This indicates that `struct net_device` is an important connection point between the generic networking stack and the mechanisms that control how packets are queued, segmented, and processed.

### 3.6 Statistics and device state

The definition contains both legacy and newer statistics-related fields:

```c
struct net_device_stats stats; /* not used by modern drivers */
struct net_device_core_stats __percpu *core_stats;
```

It also contains fields such as:

```c
atomic_t carrier_up_count;
atomic_t carrier_down_count;
unsigned int operstate;
unsigned char link_mode;
bool up;
```

These fields help represent operational state and monitor link transitions. The source explicitly comments that `struct net_device_stats` is not used by modern drivers, so it should not be treated as the primary modern statistics mechanism.

### 3.7 Protocol and subsystem integration

`struct net_device` contains pointers to data structures used by different networking protocols and kernel subsystems. Examples in the inspected definition include:

- `ip_ptr` for IPv4-related device information.
- `ip6_ptr` for IPv6-related device information.
- `vlan_info` for VLAN configuration.
- `dsa_ptr` for Distributed Switch Architecture integration.
- `ieee80211_ptr` for wireless-device integration.
- `mpls_ptr` for MPLS-related information.
- `xdp_prog` and XDP-related fields for eXpress Data Path support.

Many of these fields are conditional on kernel configuration options. Consequently, the exact set of fields available in a particular kernel build can depend on its configuration.

### 3.8 Device lifecycle, synchronization, and memory management

The structure also contains fields used to manage registration, teardown, references, and synchronization. Examples include:

```c
struct mutex lock;
refcount_t dev_refcnt;
bool dismantle;
bool needs_free_netdev;
void (*priv_destructor)(struct net_device *dev);
```

The source comments describe the purpose and protection rules of the `lock` field in detail. They explain that different fields are protected by different combinations of the device lock and `rtnl_lock`, and that callers should use the appropriate helper functions.

The final member is:

```c
u8 priv[] ____cacheline_aligned
       __counted_by(priv_len);
```

This is a flexible array member for device-private data. The associated `priv_len` field records its length. It provides space for data specific to a network device or driver without requiring every driver-specific field to be part of the common structure definition.

## 4. Cache-line organization

One notable aspect of the definition is its explicit organization into cache-line groups:

- `net_device_read_tx`
- `net_device_read_txrx`
- `net_device_read_rx`

The comments identify these groups with the transmit path, the shared transmit/receive path, and the receive path.

This organization is intended to keep fields that are commonly accessed together near each other in memory. Such layout decisions matter in networking because packet processing can access these fields very frequently. Organizing them with cache behavior in mind can help reduce unnecessary cache-line sharing and improve access efficiency.

The structure also has comments identifying fields and groups mostly used on the receive and transmit paths. This shows that performance considerations influence not only the functions that use `struct net_device`, but also the layout of the structure itself.

## 5. Device operations: `netdev_ops`

One of the most important fields near the beginning of the structure is:

```c
const struct net_device_ops *netdev_ops;
```

This field is a pointer to a `struct net_device_ops` object. It is not itself a function. Instead, it points to a table of operations that a network device or its driver provides.

The `const` qualifier means that the operations table is treated as read-only through this pointer. The actual callbacks are defined by the `struct net_device_ops` type and populated by the relevant device or driver implementation.

This design allows the generic networking code to invoke device-specific behavior through a common interface. The networking stack can call an operation through `dev->netdev_ops` without needing to hard-code the implementation for every network device.

The inspected `struct net_device` excerpt establishes the existence and type of the `netdev_ops` pointer. It does not include the definition of `struct net_device_ops` or show which callbacks are populated by a particular driver. Those details must be examined separately in the source code before documenting individual operations.

The next source-code inspection will therefore focus on:

1. Locating the definition of `struct net_device_ops`.
2. Identifying important callbacks in that operations table.
3. Finding where a device or driver assigns its operations table to `dev->netdev_ops`.
4. Following selected callbacks into their implementations.

## 6. Initial findings

From examining the `struct net_device` definition, the following points can be established:

1. `struct net_device` is the common kernel representation of a network interface.
2. It stores information for both transmit and receive processing, including queue pointers, MTU, offload limits, and feature flags.
3. It links the generic networking subsystem to device-specific behavior through the `netdev_ops` pointer.
4. It contains state, address, statistics, protocol-integration, and lifecycle-management information.
5. Its fields are deliberately organized around transmit and receive access patterns, with cache-line organization explicitly documented in the source.
6. It contains synchronization and reference-management fields because network devices are accessed by multiple parts of the kernel and can be reconfigured or removed during operation.

## 7. Monitoring nested function calls with ftrace

*This section will be completed after the ftrace experiment.*

The next step is to use `ftrace` to observe the kernel functions called during network-device operations. The aim is to identify a suitable operation or networking path, record its function-call sequence, and relate the observed calls to the fields and callbacks found in `struct net_device`.

The final report will include the tracing configuration, commands used, relevant function-call output, and an explanation of the observed call sequence.

## 8. Conclusion

The source-code inspection shows that `struct net_device` is much more than a structure containing a network interface's name and MTU. It is a central object connecting the generic networking stack to device queues, protocol-specific components, statistics, offload capabilities, and driver-provided operations.

The `netdev_ops` pointer is especially important because it provides the interface through which generic networking code can request device-specific operations. The next stage of the assignment will use `ftrace` to observe how these operations and related kernel functions are called at runtime.
