# Design notes

These notes explain how gpushare is built and why. The rules themselves are in [AGENTS.md](../AGENTS.md); this document is for maintainers, contributors and security reviewers.

## Goals and non-goals

**Goals**
- People and AI agents on one shared host coordinate GPU use with rules both can follow.
- No infrastructure: no daemon, no database, no service account.
- The whole state can be read with `ls` and `cat`.
- Nobody can destroy someone else's place in line.
- Crashed or abandoned sessions never block the queue.
- One `sudo` command to install, `rm -rf` to remove.

**Non-goals**
- Enforcement.
- Accounting or fair-share over time.
- Multiple hosts.
- Forced preemption.

## Why files

- **No client to install.** Every coding agent can already list, read and append to files and run shell commands, so the protocol needs no client library, API or credentials.
- **Readable and auditable.** The queue is a directory listing and a job's history is its lock file, so people can inspect, audit and debug it with standard tools.
- **The key guarantee comes free.** Unix permissions provide the one guarantee that matters: you can't delete another user's claim. The kernel enforces it, and no code of ours has to get it right.
- **Nothing to maintain.** There is no process to crash, restart, upgrade or secure.

The cost is the lack of transactions. Every change is either an atomic append or happens under a per-GPU `flock` (see [Concurrency](#concurrency)).

## Layout and permissions

```
/srv/gpushare/          root:root 1777   world rwx + sticky bit; created by the admin
├── .git/, *.md,        owned by the maintainer, not writable by others (setup.sh re-applies go-w)
│   bin/, docs/, etc/,
│   hosts/, tests/
└── gpuN/               root:root 1777 + default ACL d:u::rwx,d:g::rwx,d:o::rwx (created by setup.sh, ignored by git)
    ├── .gpu-info       root 0644: index, uuid, name, pci_bus_id, memory_total_mib
    ├── .mutex          root 0644: flock target
    └── NNNN-user-job   lock files, 0666, owned by whoever queued
```

- **Sticky bit:** everyone can create files, but only a file's owner, or root, can delete or rename it.
- **`gpuN/` owned by root:** the owner of a sticky directory may delete anything in it, so a regular user must not own these directories, not even the maintainer.
- **Default ACL:** a new lock file gets mode 0666 whatever the creator's umask, so everyone can read it and append pings.
- **`fs.protected_regular`** (`1` on systemd distributions):
  - In a sticky, world-writable directory, the kernel refuses `open(O_CREAT)` on an existing file owned by someone else, even when the file is 0666. So `>>`, `tee -a` and Python's `open(p, "a")` fail on another user's lock.
  - That's why `gpuq` appends with `O_WRONLY|O_APPEND` and no `O_CREAT`; by hand, use `dd conv=nocreat,notrunc oflag=append`.
  - Leave the sysctl on: it protects `/tmp` against file-planting attacks.
- **Hardening the world-writable top folder:**
  - `bin/` is writable only by the maintainer, so nobody can plant a module next to `gpuq`. As defence in depth, `gpuq` also runs Python with `-I` (isolated mode): it ignores `PYTHON*` variables and user site-packages, and doesn't import from the script's folder. That keeps the shared tool's behaviour independent of each user's Python setup, and keeps copies of `gpuq` safe even if they end up in a world-writable folder;
  - `.gitignore` whitelists the tracked paths, so stray files never get committed;
  - `setup.sh` runs as root, so it refuses `gpuN` paths that are symlinks or are not owned by root, and it writes its own files through `mktemp` + `mv`.

## Lock files

- **The name** `NNNN-user-job` carries the queue order. Four zero-padded digits make lexical order equal numeric order in `ls`. New jobs take the highest number + 10; numbering starts at 1000, which leaves room to cut in front.
- **The header** (`key: value`) is written once, when the lock is created.
- **After the header,** everyone only appends log lines: `<ISO time> <user>@<host> <VERB> <text>`. On a local filesystem, small `O_APPEND` writes don't interleave, so concurrent writers can't corrupt each other's lines. Nobody rewrites the file, not even its owner.
- **Ownership:** `STATUS` and `PID` lines count only when the file's owner wrote them, judged by the user name in the line compared with `st_uid`. The `[assigned user]` mark compares `st_uid` with the hosts file. The file name and header are never trusted.
- **Versioning:** the first header line, `# gpuq lock v1`, versions the format. Every running queue on every server reads locks written by whatever version created them, so changes must stay backward compatible.

## Liveness

A lock records the PIDs that keep it alive, each with its start time from `/proc/<pid>/stat`, so a reused PID never counts as alive:
- the **owner** process: `$CLAUDE_PID` in Claude Code, otherwise the first ancestor that isn't a shell (agent CLI, sshd session, tmux);
- the **`gpuq run`** process;
- the **job** process.

A lock with no living PID is **stale**. Everyone ignores it, but only its owner (`gpuq prune`) or root can delete it.

Why PIDs and not heartbeats? Agents can't reliably run periodic tasks, and people forget them. PIDs cost nothing and follow the actual lifetime of the session and the job.

## Turn order

For each GPU, a job may start when:
- no other live lock is running;
- no live, unskipped, queued lock comes before it in `(number, created, name)` order;
- nvidia-smi shows no compute process from a user without a running lock there.

Sharing is the one exception: a `--share` job may start next to `--share` jobs when the declared memory, and the memory nvidia-smi actually reports free, both leave 1 GB of headroom.

Running jobs are never preempted automatically. Killing someone's job is destructive, and the right call depends on context (a deadline? nearly done?), so the decision is negotiated through pings instead.

## No-shows: TURN and SKIP

The rule: a job at the head of the queue that never starts must not block everyone behind it.

**Who keeps track.** Every `gpuq` that is waiting, checking or claiming also acts as an observer, and runs a pass over its GPU's queue:
- The first queued job whose turn it is gets a `TURN` line. Only transitions are written, so a quiet queue produces no lines.
- If that job is still queued `TURN_GRACE` seconds later (900 by default), it gets a `SKIP` line, and the jobs behind it may go first.
- A job that stops being first before it started gets `NOTURN`.

**Coming back.** A skipped job keeps its number. As soon as its owner runs `gpuq wait`, `run`, `start` or `check`, gpuq appends an owner `STATUS queued` line, and the job is back in line. It gets the GPU the next time the GPU is free.

**Why the markers live in the lock file:** that needs no extra state, and the owner's `gpuq watch` shows them as notifications.

**Multi-GPU jobs:** while such a job waits for its other GPUs, it can't keep one GPU idle for more than `TURN_GRACE`.

## Concurrency

Join (picking a number), claim (`STATUS running`) and renumber happen under an exclusive `flock` on `gpuN/.mutex`. For multi-GPU jobs, the mutexes are taken in a fixed order. This stops two waiters from both deciding it is their turn. Everything else is a single append or a read.

## Usage outside the queue

nvidia-smi's compute-process list is mapped to Unix users through `/proc/<pid>`. A user's processes count as registered if that user has a running lock on that GPU; any others mean the GPU is busy. `--ignore-unregistered` overrides this; the rules allow it only with the consent of the process owner or the GPU's assigned user, and gpuq still checks that the memory is free.

## Threat model

gpushare assumes colleagues who are **cooperative but fallible**, and their agents. It protects against accidents and confusion, not against a malicious local user, who can ignore the queue entirely anyway.

**Guaranteed** (by the kernel and the layout):
- Nobody but the owner or root can delete or rename a lock.
- Only the maintainer can change the code, the rules (AGENTS.md) or the assignments, and planted Python modules aren't imported.
- Root's `setup.sh` can't be tricked into changing permissions on files it didn't create.

**Not guaranteed** (cooperative):
- Lock **contents** are writable by everyone, because pings need that. Anyone can append misleading lines (fake senders, fake `TURN`/`SKIP`), and someone determined can even overwrite or truncate the content with tools that open the file without `O_CREAT`. The author field of a log line is not authenticated. Only the file owner is.
- **Prompt injection:** pings are text from other users that agents read. AGENTS.md therefore makes ping text information, not instructions: a ping can only lead an agent to reply, yield, leave or move its own lock, and anything else goes to its human. The agent-facing pointer (`etc/claude-code-CLAUDE.md`) repeats this rule.
- **Assigned-user claims** in a ping are not proof. A yield request is binding only when the assigned user has their own lock on the GPU, checked by file owner.
- **Flooding:** anyone can create many locks, or hold `.mutex` open so that joins time out after 60 s. Both are visible in `gpuq status` and `ls -l`, and root can clean up.
- **GPU use without a lock** is detected, not prevented.

## Testing hooks

`tests/sim.sh bin/gpuq` runs a full simulation in a temporary folder. The same hooks are available by hand:

| Variable | Effect |
|---|---|
| `GPUQ_ROOT=<dir>` | use `<dir>` (containing `gpuN/.gpu-info`) as the queue |
| `GPUQ_NO_SMI=1` | skip nvidia-smi |
| `GPUQ_FAKE_SMI=<dir>` | read `gpus.csv` and `apps.csv` from `<dir>` instead of calling nvidia-smi |
| `GPUQ_TURN_GRACE=<s>` | grace period before a no-show is skipped (default 900) |
