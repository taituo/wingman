# Wingman

Split-screen tmux with Amazon Q integration and workspace management.

## Getting Started

```bash
git clone <repo>
cd wingman
./fly.sh
```

The menu offers:
1. Start wingman workspace (CLI | Amazon Q)
2. Attach to existing workspace
3. Stop & remove workspace
4. List workspaces
5. Exit

## How it works

- Creates numbered workspaces (`workspace_001`, `workspace_002`, ...)
- Each workspace has tmux session with CLI | Amazon Q + Capcom
- Type `#q analyze this error` in CLI → Capcom sends "analyze this error" to Amazon Q
- Capcom monitors logs, sets up workspace SPEC files, ensures Q is ready

## Requirements

- tmux
- Amazon Q CLI (`q chat`)

## Direct Usage

```bash
./fly.sh          # Start here (main entry point)
```
