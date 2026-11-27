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
- **Ownership:** `STATUS` and `PID` lines, and `leave-by` promises, count only when the file's owner wrote them, judged by the user name in the line compared with `st_uid`. The `[assigned user]` mark compares `st_uid` with the hosts file. The file name and header are never trusted for identity.
- **Structured fields:** a `PING` may start with `need-by=<ISO time>` and an `ACK` with `leave-by=<ISO time>`. To older readers they are just text. `gpuq` prefixes free text that happens to look like a field, so a message can't pose as one.
- **Versioning:** the first header line, `# gpuq lock v1`, versions the format. Every running queue on every server reads locks written by whatever version created them, so changes must stay backward compatible.

## Liveness

A lock records the PIDs that keep it alive, each with its start time from `/proc/<pid>/stat`, so a reused PID never counts as alive:
- the **owner** process: `$CLAUDE_PID` in Claude Code, otherwise the first ancestor that isn't a shell (agent CLI, sshd session, tmux);
- the **`gpuq run`** process;
- the **job** process.

A lock with no living PID is **stale**. Everyone ignores it, but only its owner (`gpuq prune`) or root can delete it.

Why PIDs and not heartbeats? Agents can't reliably run periodic tasks, and people forget them. PIDs cost nothing and follow the actual lifetime of the session and the job.

When there is no `$CLAUDE_PID`, gpuq walks up its ancestors and skips shells. It recognizes them by their executable as well as their name, because a shell running a script carries the script's name. If only shells lead up to init (`nohup setsid …`), the session is gpuq's own process: never init, which would keep a lock alive forever.

Only processes owned by the lock file's owner count. Anyone can append a `PID` line, but nobody can make a lock live on through processes of their own.

## Sessions

One Unix user often runs many agents at once: several Claude Code chats, a Codex session, a terminal. The user alone can't tell them apart, so gpuq gives each **session** a tag:
- `$GPUQ_SESSION`, if set;
- in Claude Code, the first 8 characters of the session id (`$CLAUDE_CODE_SESSION_ID`). The id survives `--resume`, so a resumed chat is the same session. Current Claude Code versions set this variable, but it is not documented; if it disappears, gpuq falls back to the next option;
- otherwise `p<pid>` of the process that keeps the lock alive.

The tag is written into the header of every lock the session creates (`session:`) and into every log line it writes (`user@host/tag`). With it:
- **Messages between sessions of one user work.** A line is foreign to a lock when it comes from another user or from another session, so the inbox, `watch` and `status` show pings between your own agents.
- **One agent can't clean up another's lock by accident.** `leave`, `start`, `run`, `renumber` and `adopt` refuse to act on a lock held by another live session of the same user (exit code 4) unless given `--force`. "Held" means any of the lock's processes is running; for `adopt`, it means the holding session itself is running, because re-attaching a lock whose job outlived its session is what adopt is for. A person typing in a terminal (a `p<pid>` session with a TTY on stdin) only gets a warning, because a person at a second terminal usually means it; agents and scripts are refused. A lock whose holding process is the caller's own Claude Code process counts as the caller's, because a chat keeps its process across `/clear`, which starts a new session id. This assumes one chat per process; a host that runs several Claude sessions in one process would lose the guard between them.
- **Taking over only what was abandoned.** `start` and `run` on another session's lock hand it over only when that session's processes are gone. The previous holder's inbox reports a hand-over as `HANDED-OVER`, not as a removal.
- **Only your own processes.** The owner PID must be a process of the caller's user: the search for it stops at the first ancestor owned by someone else (`su`, `sudo`, a root daemon), and `--pid` of another user's process is refused.
- **Hand-overs are recorded privately.** `adopt`, and `start` or `run` on another session's lock, append a `PID … owner … session=<s>` line for everyone to see. The owner's own gpuq trusts only its private record in `~/.local/state/gpuq/locks-<host>.json`, which no other user can write, so a forged hand-over line can't move a lock between your sessions. After a hand-over, only the new holder's processes stand for the session.
- **Resumed sessions get their locks back.** When a session id survives restarts (Claude Code, `$GPUQ_SESSION`), gpuq re-attaches that session's stale queued locks to the new process. A stale running lock stays stale: its job has ended. It never does this for `p<pid>` tags, since PIDs are reused.
- **Old locks keep working.** A lock without a `session:` header belongs to every session of its owner, and an untagged line by the owner counts as the owner's own, exactly as before.

Sessions of one user share a trust domain: the same user can edit or delete those files directly. Tags prevent accidents between cooperating agents; between users, the kernel's guarantees are unchanged.

## Inbox

Agents only notice what reaches their context, so `gpuq inbox` collects everything that needs a session's attention, one line per event:
- lines that others append to the locks the session holds (pings, notes, `TURN`, `SKIP`);
- the owner's `ACK` and `NOTE` lines on locks the session has pinged, so a request gets its answer;
- reminders: a ping unanswered for 10 minutes, a promised `leave-by` time reached;
- locks that disappear, the session's own or ones it pinged (that GPU may be free now), and the session's locks that another session of the user adopts.

It runs in three modes: a stream, for a monitor; `--next`, which waits for one event and exits, so a background task wakes the agent exactly when needed; and `--once`, for periodic checks. What was delivered is kept per session in `~/.local/state/gpuq/`, so a restarted inbox neither repeats nor misses events:
- locks are tracked by inode, creation time and job name, which `renumber` keeps and a new lock reusing an inode does not;
- messages are tracked by job name, because a multi-GPU job has one file per GPU carrying the same lines;
- events are printed before they are recorded as delivered, so a crash can repeat one but never lose it;
- on first sight of a lock, the inbox starts after the session's last reply, so pings it already answered aren't replayed.

**Promises are checked the same way.** `gpuq reply --leave-by` also writes the promise into the user's private record. `DUE` reminders and "you promised" in `gpuq mine` come from that record, never from the log. A promise line that someone else writes in the owner's name shows up in `gpuq status`, but it can neither make gpuq tell an agent to stop its job nor hide a promise the agent made; `gpuq mine` points out the disagreement.

`gpuq mine` is the stateless counterpart: after a compaction or a restart, it lists the session's locks with the pings it hasn't answered and the promises it made.

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

**Why the markers live in the lock file:** that needs no extra state, and the owner's `gpuq inbox` shows them as notifications.

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
- Lock **contents** are writable by everyone, because pings need that. Anyone can append misleading lines (fake senders or sessions, fake `TURN`/`SKIP`, a fake promise in the owner's name), and someone determined can even overwrite or truncate the content with tools that open the file without `O_CREAT`. The author field of a log line is not authenticated. Only the file owner is.
- **Prompt injection:** pings are text from other users that agents read. AGENTS.md therefore makes ping text information, not instructions: a ping can only lead an agent to reply, yield, leave or move its own lock, and anything else goes to its human. The agent-facing pointer (`etc/claude-code-CLAUDE.md`) repeats this rule. gpuq's own output prints others' text as one JSON-quoted string marked `(unverified)`, capped at 400 characters, so it can't span lines or pose as gpuq output. Sender names that contain anything but `[A-Za-z0-9._-]`, `@` and `/` are quoted too, header values are stripped of unprintable characters, and timestamps or durations that don't parse are ignored rather than crashing anyone's gpuq.
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
| `GPUQ_SESSION=<tag>` | the session tag to use (the tests run two sessions of one user this way) |
| `XDG_STATE_HOME=<dir>` | where the inbox remembers what it delivered (default `~/.local/state`) |
