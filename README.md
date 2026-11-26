# gpushare: maintainer notes

This is a cooperative GPU queue. The protocol for users and agents is in [AGENTS.md](AGENTS.md). `gpuq` is the helper that implements it, and `setup.sh` prepares a host. This file is for whoever maintains the folder.

## Layout and permissions

```
/srv/gpushare/          root:root 1777   world rwx + sticky bit; created by hand with sudo
├── .git/, *.md,        maintainer-owned, not writable by others (setup.sh re-applies go-w)
│   bin/gpuq, setup.sh,
│   hosts/, etc/, tests/
└── gpuN/               root:root 1777 + default ACL d:u/g/o::rwx; not in git, created by setup.sh
    ├── .gpu-info       root 0644: index, uuid, name, pci_bus_id, memory_total_mib
    ├── .mutex          root 0644: flock target that serializes gpuq join/claim/renumber
    └── NNNN-user-job   lock files, 0666, owned by whoever queued
```

Why it is set up this way:

- **Sticky bit (`1777`):** everyone can create files, but only a file's owner (or root) can delete or rename it. This is what keeps users from removing each other's locks.
- **`gpuN/` owned by root:** the owner of a sticky folder can still delete everything in it, so these folders must not belong to a regular user, including the maintainer.
- **Default ACL:** every new lock gets mode 0666 whatever the creator's umask. That keeps every lock readable and lets others append pings.
- **`fs.protected_regular=1` (systemd default):**
  - In a sticky, world-writable folder, the kernel refuses `open(O_CREAT)` on an existing file owned by someone else, even when the file is mode 0666. That breaks `>>`, `tee -a` and Python `open(p, "a")` on other people's locks.
  - This is why pings use `O_WRONLY|O_APPEND` without `O_CREAT` (`gpuq ping`, or `dd conv=nocreat,notrunc oflag=append`).
  - Don't turn the sysctl off: it protects `/tmp` against file-planting attacks.
- **Hardening against the world-writable top folder:**
  - `gpuq` lives in `bin/`, which only the maintainer can write to, and it starts Python with `-I` (isolated mode) so it never imports from the script's folder, the current folder or `PYTHON*` variables. Either way, a planted `json.py` can't run as the user calling gpuq.
  - `.gitignore` whitelists only the tracked paths, so stray files can't be committed by accident.
  - `setup.sh` refuses `gpuN` paths that are symlinks or not owned by root, since someone could pre-create them to trick root into a `chmod`.

## Install on another server

```bash
sudo mkdir -m 1777 /srv/gpushare                      # root-owned, sticky
git clone <repo-url> /srv/gpushare                    # as the maintainer, not root
cd /srv/gpushare
cp hosts/example.json hosts/$(hostname -s).json       # then edit: UUIDs (nvidia-smi -L), assigned users, links
sudo ./setup.sh
```

Keep the folder on a local disk. Every server needs its own queue, so never share one folder between hosts over NFS.

## Updating

- Edit, test (`tests/sim.sh bin/gpuq`), commit, push.
- **On each server:** `git -C /srv/gpushare pull`. Rerun `sudo ./setup.sh` if the GPUs changed.
- **Optional, push straight to a server:** run `git config receive.denyCurrentBranch updateInstead` in that server's checkout, and a `git push` from any clone updates its live files in place. The push is refused if the server's checkout has uncommitted changes.

Locks in a running queue survive updates. Keep the lock format backward compatible, or drain the queues first.

## Assignments

`hosts/<host>.json` is per-server configuration and is **not tracked in git**, because it names people. Start from [hosts/example.json](hosts/example.json). The file holds:
- `gpus`: for each GPU index, its UUID, the assigned unix user, and the person's name as it appears in your reservation system;
- `reservations` and `discussion`: links that `gpuq status` prints (reservation system, chat channel).

It is maintained by hand: when a reservation changes, update the file and its `"updated"` field. `gpuq` warns if a UUID in it doesn't match `gpuN/.gpu-info`. If your reservation system can export its data, a cron job could regenerate the file instead.

## After the beta

```bash
sudo /srv/gpushare/setup.sh --install-pointers
```

That installs three things:
- the block from `etc/claude-code-CLAUDE.md` into `/etc/claude-code/CLAUDE.md`, which every Claude Code session on the machine loads;
- the line from `etc/motd.snippet` into `/etc/motd`;
- a `/usr/local/bin/gpuq` symlink (users can also add `/srv/gpushare/bin` to their PATH).

Then announce it to the people who use the server. Ask people who use other agent CLIs to add the same pointer to those tools' global instructions (Codex: `~/.codex/AGENTS.md`).

## Admin tasks

- `sudo /srv/gpushare/bin/gpuq prune` removes every stale or done lock (all of their PIDs have exited).
- `sudo /srv/gpushare/bin/gpuq leave <id>` removes one specific abandoned lock. Tell its owner.
- `/srv/gpushare/bin/gpuq status` gives the full picture, including GPU processes that have no lock.

## Testing

`tests/sim.sh bin/gpuq` runs the simulation in a temporary folder. It never touches the real queue or the GPUs. The same hooks are available by hand:

- `GPUQ_ROOT=<dir>`: use another folder (with `gpuN/.gpu-info`) as the queue.
- `GPUQ_NO_SMI=1`: skip nvidia-smi.
- `GPUQ_FAKE_SMI=<dir>`: read `gpus.csv` and `apps.csv` from there instead of calling nvidia-smi (see `tests/sim.sh` for the format).
- `GPUQ_TURN_GRACE=<seconds>`: how long the first job may wait before starting once its turn has come (default 900).
