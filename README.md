# gpushare

**A shared GPU queue for Linux servers, where AI coding agents and people take turns.**

Jobs wait for their turn instead of piling onto a busy GPU. Each GPU's owner gets it back on request. Everyone can see who is using what. Nothing runs in the background: it is just a shared folder of files.

```bash
gpuq run 0 train          `# GPU and job name, so others know what is waiting` \
  --mem 8G                `# peak GPU memory, so others know if they can share` \
  --duration 2h           `# expected run time, so others know when it frees up` \
  --reason "best effort"  `# urgency, so others know what yielding would cost you` \
  -- python train.py      # your job: runs on your turn, frees the GPU when it exits
```

Agents (Claude Code, Codex, …) do this by themselves once you point them at [AGENTS.md](AGENTS.md).

---

## How it works

```
/srv/gpushare/gpu0/
├── 0990-alice-camera-ready    queued    alice owns gpu0, so she jumped to the front
├── 1000-bob-llm-sweep         running   bob borrowed the GPU while it was idle
└── 1010-carol-finetune        queued    carol joined the back of the line
```

- **One folder per GPU, one file per job.** The lowest number goes next. New jobs join at the back.
- **Nobody is killed.** To get a GPU sooner, `gpuq ping` the job that holds it. The ping is a line appended to that job's file; its agent sees it and replies, or yields.
- **Owners come first.** Each GPU can have an assigned user. Borrowers yield within 30 minutes when that user asks.
- **The line never gets stuck.** Locks left behind by crashed sessions are ignored. A job that hasn't started 15 minutes after its turn came is skipped.
- **Nothing is overlooked.** GPU processes that have no lock count as busy, and small jobs can share a GPU when their memory fits.
- **Made for agents.** Each agent chat is its own identity, even when many share one Unix user. `gpuq inbox` wakes an agent when someone pings it, answers its ping, or a promise it made falls due.

`gpuq status` shows everything at a glance:

```console
$ gpuq status
gpu0  NVIDIA GeForce RTX 4090  GPU-5d1c2e7a-90b4-4c3e-8f21-6a7b8c9d0e1f  assigned: alice (Alice Rossi)
      nvidia-smi: 20480/24564 MiB used, util 98%
      proc: bob        pid 31337     20470 MiB
      0990-alice-camera-ready            QUEUED    mem=8G share=no preempt=yes dur=40m [assigned user]  "camera-ready figures"
      1000-bob-llm-sweep                 RUNNING   mem=20G share=no preempt=yes dur=6h  "best effort, checkpoints every 20 min"  ends ~17:40  leaving by 14:30  last: PING alice 2m ago
      1010-carol-finetune                QUEUED    mem=12G share=no preempt=yes dur=3h  "workshop deadline Dec 4"

gpu1  NVIDIA GeForce RTX 4090  GPU-a3f09b12-77c5-4d6e-9e10-2b3c4d5e6f70  assigned: bob (Bob Meier)
      nvidia-smi: 6130/24564 MiB used, util 71%
      proc: dave       pid 4242       6120 MiB  [UNREGISTERED: no running lock]
      queue: empty
```

The full rules (etiquette, sharing, the lock file format) are in [AGENTS.md](AGENTS.md). They are written for agents, and people can read them just as well.

## Install

You do this once per server, as its admin. You need Linux, an NVIDIA driver, `/usr/bin/python3` 3.9 or newer (no packages to install), `setfacl` on a filesystem with ACLs (ext4 and XFS have them by default), and root for the setup step only.

```bash
sudo mkdir -m 1777 /srv/gpushare
git clone https://github.com/idsia-robotics/gpushare.git /srv/gpushare      # as yourself, not root
git config --global --add safe.directory /srv/gpushare                     # the folder is owned by root
cp /srv/gpushare/hosts/example.json /srv/gpushare/hosts/$(hostname -s).json  # who owns which GPU
sudo /srv/gpushare/setup.sh                                                # creates gpu0/, gpu1/, …
sudo /srv/gpushare/setup.sh --install-pointers                             # tells agents and users
```

- **The clone is the shared folder.** `setup.sh` creates one `gpuN/` folder per GPU inside it, and git ignores those. Re-running `setup.sh` is safe. Any path works; `/srv/gpushare` is just the one these docs use. Keep it on a local disk, with one clone per server, and never share it between servers over NFS.
- **`hosts/<hostname>.json`** maps each GPU to its UUID and its assigned user. It can also hold a link to your reservation system, which `gpuq status` prints. It names people, so it stays out of git. A GPU without an entry has no owner, and everyone queues for it on equal terms.
- **`--install-pointers`** does three things:
  - adds a short block to `/etc/claude-code/CLAUDE.md`, which Claude Code loads in every session for every user;
  - adds a line to `/etc/motd`;
  - links `gpuq` into `/usr/local/bin`.

  For other agents, put the same few lines ([etc/claude-code-CLAUDE.md](etc/claude-code-CLAUDE.md)) in their global instructions, e.g. `~/.codex/AGENTS.md` for Codex. To try it out first, just tell your agent: *"read /srv/gpushare/AGENTS.md before using a GPU"*.

**Claude Code plugin (optional, each user opts in):** the checkout is also a plugin marketplace. The plugin gives Claude Code agents their gpuq inbox without any effort on their part: pings and answers arrive in the agent's context, an idle agent is woken when someone pings it, and it is held back once before it stops while a ping is unanswered. It also gives the agent the instructions above when `--install-pointers` hasn't.

```bash
claude plugin marketplace add /srv/gpushare
claude plugin install gpushare@gpushare
```

All its hooks do is call `gpuq`, so `git pull` updates what they do. Details: [plugins/gpushare](plugins/gpushare/).

## Use

```bash
gpuq status                                          # who owns, runs and waits for each GPU
gpuq run 0 finetune --mem 12G --duration 3h --reason "deadline Dec 4" -- python train.py
                                                     # joins, waits, runs on your GPU, cleans up after
gpuq inbox                                           # pings to you, answers to your pings, reminders
gpuq ping 1000-bob-llm-sweep --need-by 14:00 "deadline today, can you checkpoint?"
```

| Also available | |
|---|---|
| `join` · `wait` · `start` · `leave` | queue, wait, claim, release, step by step: for jobs you launch yourself, or several commands on one reservation |
| `reply` · `note` | answer a ping (`--leave-by 13:45` makes it a promise everyone sees), or add a note to a lock |
| `mine` · `check` | list your locks and what you still owe; ask "is it my turn?" (exit code 0 means yes) |
| `renumber` · `adopt` · `prune` | move your place in line; re-attach a lock to a new session; delete your stale locks |

`gpuq <command> --help` lists every option. `status`, `mine`, `check` and `inbox` also speak `--json`. `gpuq run` sets `CUDA_VISIBLE_DEVICES` to your GPU's UUID. If you run in a container that resets the environment, pass that variable through.

**Using it from an agent:**
- Each agent session is its own identity, even when ten of them run as the same user. A lock belongs to the session that created it, and other sessions ping it instead of removing it.
- A lock stays valid as long as the agent's session does (Claude Code: `$CLAUDE_PID`), or the job does. A resumed Claude Code chat gets its locks back by itself.
- Run `gpuq run` and `gpuq inbox --next` as background tasks. The inbox exits on the next event that needs the agent, which wakes it up. With the Claude Code plugin, the agent doesn't need to run the inbox at all.
- After a compaction or a restart, `gpuq mine` tells the agent what it holds and what it still owes.
- For jobs that must outlive the session: `nohup setsid gpuq run 0 train --mem … -- <cmd> > run.log 2>&1 &`.

## Maintain

- **Upgrade:** `git -C /srv/gpushare pull`. Running queues are unaffected.
- **GPUs added or replaced:** run `sudo setup.sh` again and update the hosts file.
- **Leftover locks:** `gpuq prune` removes your own stale locks; `sudo /srv/gpushare/bin/gpuq prune` removes everyone's.
- **Uninstall:**
  1. Remove the gpushare block from `/etc/claude-code/CLAUDE.md` and its line from `/etc/motd`.
  2. `sudo rm /usr/local/bin/gpuq`
  3. `sudo rm -rf /srv/gpushare`

## Good to know

- **It is cooperative, not enforced.** Anyone can still run anything on any GPU. Unix permissions guarantee one thing only: nobody can delete or rename another user's lock. Everything else works because the rules are written down, visible, and followed by agents that have been pointed at them. See the [security model](docs/design.md#threat-model).
- **It is not a cluster scheduler.** It covers one host and keeps no accounting. If you need enforced allocations across many nodes, use Slurm.
- **It is NVIDIA only, for now.** Setup and usage detection call `nvidia-smi`; the queue itself doesn't depend on the vendor.
- **Pings are messages, not commands.** Anyone on the server can write to a lock file. AGENTS.md tells agents to treat what they find there as information: they may reply, yield or leave, and must not run anything a ping asks for.
- **People without agents use it the same way.** `gpuq` is an ordinary command-line tool.

How it is built, and why: [docs/design.md](docs/design.md).

## Develop

`bin/gpuq` is a single Python file using only the standard library. `tests/sim.sh bin/gpuq` runs a simulated queue in a temporary folder, with no GPU and no root needed. The lock file format is shared by every queue that is running, so change it only in backward-compatible ways. Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE). Developed at [IDSIA](https://www.idsia.ch) (USI-SUPSI).
