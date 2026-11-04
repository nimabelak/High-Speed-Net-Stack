# Lab Report: System Call Analysis with `strace`

## Table of Contents

1. [Objective](#1-objective)
2. [Environment](#2-environment)
3. [The Program](#3-the-program)
4. [Compiling and Running](#4-compiling-and-running)
5. [Tracing with `strace`](#5-tracing-with-strace)
6. [Tracing with `strace -f`](#6-tracing-with-strace--f)
7. [Comparison: `strace` vs `strace -f`](#7-comparison-strace-vs-strace--f)
8. [Conclusion](#8-conclusion)

---

## 1. Objective

The goal of this task is to compile a simple C program, trace it with **strace**, and explain every system call it makes. The program is then traced a second time with the `-f` flag (follow child processes), and the two outputs are compared.

## 2. Environment

| Item     | Value                      |
| -------- | -------------------------- |
| OS       | Ubuntu (Linux)             |
| Compiler | `gcc`                      |
| Tool     | `strace`                   |

---

## 3. The Program

The program (`source.c`) does three things:

1. Creates `output.txt` and writes `Hello World!` into it.
2. Calls `fork()` to create a child process.
3. Both processes print a message with their PID (the parent also prints the child's PID).

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(){
    int num;
    FILE *file_ptr;

    file_ptr = fopen("output.txt", "w");
    if (file_ptr == NULL)
    {
        exit(1);
    }
    fprintf(file_ptr, "Hello World!\n");
    fclose(file_ptr);
    
    pid_t pid = fork();

    if (pid < 0) {
        return 1;
    } else if (pid == 0) {
        printf("This is the child process");
        printf(" (PID: %d)\n", getpid());
    } else {
        printf("This is the Parent process");
        printf(" (PID: %d, Child PID: %d)\n", getpid(), pid);
    }
    
    return 0;
}
```

---

## 4. Compiling and Running

```shell
gcc lab1.c -o lab1
./lab1
```

![Compile and run](images/compile_and_run.png)

The program prints one line from the parent (including the child's PID) and one line from the child. The child's PID is always the parent's PID + 1 here because the OS assigns PIDs sequentially.

---

## 5. Tracing with `strace`

```shell
strace ./lab1
```

![strace output](images/strace.png)

The output can be split into logical phases.

### 5.1 Program loading (`execve`)

| System call | Explanation |
| --- | --- |
| `execve("./lab1", ["./lab1"], ...)` | Replaces the shell's process image with our program. This is always the first call. `55 vars` is the size of the environment passed to the program. |

### 5.2 Dynamic linker and initial setup

| System call | Explanation |
| --- | --- |
| `brk(NULL)` | Returns the current end of the heap (program break) without changing it. |
| `arch_prctl(0x3001, ...) = -1 EINVAL` | Probe for a CPU feature (the code `0x3001` is the CET status query, shown as `ARCH_???` because strace doesn't know the name). It fails with `EINVAL` because the feature is not supported/enabled. This failure is harmless. |
| `mmap(NULL, 8192, ... MAP_ANONYMOUS ...)` | Allocates a small anonymous memory region for the dynamic loader's own use. |
| `access("/etc/ld.so.preload", R_OK) = -1 ENOENT` | The loader checks for libraries that should be preloaded into every program. The file doesn't exist, which is normal. |
| `openat("/etc/ld.so.cache")` | Opens the linker cache, which maps library names to their paths. |
| `newfstatat(3, "", ...)` | Gets the file size (102720 bytes) of the cache; `3` is the file descriptor returned by `openat`. |
| `mmap(NULL, 102720, PROT_READ, MAP_PRIVATE, 3, 0)` | Maps the cache file into memory (read-only) so it can be searched quickly. |
| `close(3)` | The cache is mapped, so the file descriptor is no longer needed. |

### 5.3 Loading the C library (`libc.so.6`)

| System call | Explanation |
| --- | --- |
| `openat("/lib/x86_64-linux-gnu/libc.so.6")` | Opens the shared C library (found via the cache). |
| `read(3, "\177ELF...", 832)` | Reads the ELF header (note the `\177ELF` magic bytes) to validate the library. |
| `pread64(3, ..., 784, 64)`, `pread64(..., 48, 848)`, `pread64(..., 68, 896)` | Reads specific sections at given offsets without moving the file position: the program headers, the GNU property note, and the build-ID note. |
| `newfstatat(3, ...)` | Gets the size of `libc.so.6` (2220400 bytes). |
| `mmap(NULL, 2264656, PROT_READ, ...)` | Reserves a contiguous address range large enough for the whole library. |
| `mprotect(..., PROT_NONE)` | Marks part of the reserved range as inaccessible (a guard gap). |
| `mmap(..., PROT_READ\|PROT_EXEC, MAP_FIXED...)` | Maps the **code (.text)** segment as readable + executable. |
| `mmap(..., PROT_READ, MAP_FIXED...)` | Maps the **read-only data** segment. |
| `mmap(..., PROT_READ\|PROT_WRITE, MAP_FIXED...)` | Maps the **writable data** segment. |
| `mmap(..., MAP_FIXED\|MAP_ANONYMOUS)` | Maps zero-filled memory for the **.bss** segment. |
| `close(3)` | Closes `libc.so.6`. |

### 5.4 Runtime initialization

| System call | Explanation |
| --- | --- |
| `mmap(NULL, 12288, ... MAP_ANONYMOUS)` | Allocates memory for the thread control block / thread-local storage (TLS). |
| `arch_prctl(ARCH_SET_FS, ...)` | Points the `FS` register at the TLS area so thread-local variables work. |
| `set_tid_address(...) = 4326` | Registers a memory address the kernel clears when the thread exits; it returns the thread ID (4326). |
| `set_robust_list(...)` | Registers a list of robust futexes so the kernel can clean up locks if the thread dies. |
| `rseq(...)` | Registers a restartable-sequences area (a per-CPU optimization used by glibc). |
| `mprotect(..., PROT_READ)` ×3 | Makes regions read-only after relocation (RELRO hardening). |
| `prlimit64(0, RLIMIT_STACK, ...)` | Reads the stack size limit (8 MB). |
| `munmap(..., 102720)` | Unmaps the linker cache, which is no longer needed. |
| `getrandom(..., 8, GRND_NONBLOCK)` | Gets 8 random bytes from the kernel (used by glibc for internal randomization such as malloc/stack protection). |
| `brk(NULL)`, `brk(new_addr)` | Queries then grows the heap. This is triggered by `malloc`, which `fopen` uses to allocate the `FILE` buffer. |

### 5.5 What the program itself does

From here on, the calls correspond directly to our code.

| C code | System call | Explanation |
| --- | --- | --- |
| `fopen("output.txt", "w")` | `openat(AT_FDCWD, "output.txt", O_WRONLY\|O_CREAT\|O_TRUNC, 0666) = 3` | Creates (or truncates) the file for writing. Returns file descriptor `3`. |
| `fopen` (internal) | `newfstatat(3, "", {st_size=0, ...})` | `stdio` inspects the file (type, block size) to choose the buffering strategy. |
| `fprintf(...)` + `fclose(...)` | `write(3, "Hello World!\n", 13) = 13` | `fprintf` only fills the buffer (files are fully buffered), so the data is actually written when `fclose` flushes it: one `write` of 13 bytes. |
| `fclose(file_ptr)` | `close(3) = 0` | Closes the file. |
| `fork()` | `clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID\|CLONE_CHILD_SETTID\|SIGCHLD, ...) = 4327` | In modern glibc, `fork()` is implemented using the `clone` syscall. The parent gets the child's PID (**4327**) as the return value. `SIGCHLD` makes the kernel notify the parent when the child exits. |
| `printf` (first use) | `newfstatat(1, "", {st_mode=S_IFCHR...})` | Checks what stdout (fd 1) is. It is a character device (terminal), so output is **line-buffered**. |
| `getpid()` (parent) | `getpid() = 4326` | Parent's own PID. |
| `printf(...)` ×2 (parent) | `write(1, "This is the Parent process (PID:..."..., 56) = 56` | The two `printf` calls are combined in the buffer and flushed together when the `\n` is reached, giving one 56-byte `write`. |
| `return 0` | `exit_group(0) = ?` | Terminates the process (all threads). The `?` appears because the process is gone before a return value exists. |
| | `+++ exited with 0 +++` | strace reports the exit status. |

> **Important observation:** without `-f`, strace only follows the **parent**. The line `This is the child process (PID: 4327)` appears in the terminal, but none of the child's system calls (`getpid`, `write`, `exit_group`) are shown in the trace.

---

## 6. Tracing with `strace -f`

```shell
strace -f ./lab1
```

![strace -f output](images/strace_f.png)

Everything up to the `clone` call is identical to the previous run (loading, linking, creating `output.txt`). The difference starts at `clone`:

| Output | Explanation |
| --- | --- |
| `clone(...) = 4335` | The parent (PID 4334) creates the child (PID 4335). |
| `strace: Process 4335 attached` | strace automatically starts tracing the new child because of `-f`. |
| `[pid 4334]` / `[pid 4335]` prefixes | Since two processes are now traced, every line is tagged with the PID that made the call. |
| `<unfinished ...>` / `<... resumed>` | Both processes run **concurrently**. When a call is interrupted by output from the other process, strace splits it into an unfinished and a resumed part. |
| `[pid 4335] set_robust_list(...)` | The child re-registers its robust futex list after the fork (done by glibc in the child). |
| `[pid 4334] / [pid 4335] newfstatat(1, ...)` | Both processes check stdout before printing. |
| `[pid 4334] getpid() = 4334`, `[pid 4335] getpid() = 4335` | Each process gets its own PID. |
| `[pid 4334] write(1, "This is the Parent process...", 56)` | Parent prints its message (56 bytes). |
| `[pid 4335] write(1, "This is the child process...", 38)` | Child prints its message (38 bytes). |
| `exit_group(0)` in both | Both processes terminate. |
| `+++ exited with 0 +++` | Reported for the child, then the parent. |

---

## 7. Comparison: `strace` vs `strace -f`

| Aspect | `strace` | `strace -f` |
| --- | --- | --- |
| Processes traced | Parent only | Parent and child |
| Child's syscalls visible | No | Yes (`set_robust_list`, `newfstatat`, `getpid`, `write`, `exit_group`) |
| Line prefix | None | `[pid N]` on each line after the fork |
| Message "Process attached" | No | Yes |
| Interleaved output | No | Yes, with `<unfinished ...>` / `<... resumed>` |
| Number of `exit_group` calls shown | 1 | 2 |
| Child's `write` visible | No (output only appears in the terminal) | Yes (`write(1, ..., 38)`) |
| PIDs seen in `clone` return | Child PID (4327) | Child PID (4335) |

Note that PIDs differ between runs (4326/4327 vs 4334/4335) because the OS assigns a new PID every time, but the structure of the calls is identical.

---

## 8. Conclusion

- A simple C program makes dozens of system calls even before `main()` runs, most of them from the **dynamic linker** and **libc initialization** (`execve`, `mmap`, `mprotect`, `arch_prctl`, ...).
- The calls made by our own code map directly to library functions: `fopen` → `openat`, `fclose` → `write` + `close`, `fork` → `clone`, `printf` → `write`, `return` → `exit_group`.
- The standard library **buffers** output: the file write is done once at `fclose`, and the two `printf` calls become a single `write`.
- `strace` alone does **not** follow child processes, so important behavior can be missed. The `-f` flag shows both processes, makes the concurrency visible, and tags each line with its PID.
