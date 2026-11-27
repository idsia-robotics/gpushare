# gpushare plugin for Claude Code

Claude Code agents hear about pings on their GPU locks without having to keep `gpuq inbox` running:

- **News arrives by itself.** Pings on the agent's locks, answers to its pings and reminders are added to its context after each tool call and each prompt.
- **Idle agents are woken.** While the agent waits for its user, a background hook watches the inbox and wakes it when something arrives.
- **Nothing is left unanswered by accident.** Before the agent stops, it is held back once while a ping on its lock has no answer or a promised leave-by time has passed.
- **Nothing is lost.** After a compaction, a resume or `/clear`, the chat is told which locks it holds and what it still owes. After a `/clear` (or a `/resume` of another chat in the same Claude Code), the locks and promises go to the chat that Claude Code now runs.
- **It gives the agent the rules.** When the admin hasn't installed the pointer for everyone (`setup.sh --install-pointers`), the plugin points the agent at AGENTS.md at the start of each session.

Hooks print nothing when there is no news, apart from that pointer.

## Install

Each user opts in once. The gpushare checkout is also a plugin marketplace:

```bash
claude plugin marketplace add /srv/gpushare
claude plugin install gpushare@gpushare
```

New sessions use it. Remove it with `claude plugin uninstall gpushare@gpushare`.

Claude Code keeps its own copy of the plugin, but all the plugin does is call gpuq (below), so `git -C /srv/gpushare pull` updates what it does. When a release changes the plugin itself, its version goes up: `claude plugin marketplace update gpushare && claude plugin update gpushare@gpushare` fetches it.

## How it works

Every hook runs `gpuq hook <event>` through `hooks/gpuq-hook`, which uses `$GPUQ_BIN` if set, else `gpuq` next to the plugin (when it runs from a checkout, as with `claude --plugin-dir`), else `gpuq` on `$PATH` (`setup.sh --install-pointers` puts it there), else `/srv/gpushare/bin/gpuq`. The hooks are in `hooks/hooks.json`; the reasoning is in [docs/design.md](../../docs/design.md#claude-code-plugin).
