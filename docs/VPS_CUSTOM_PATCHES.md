# VPS Custom Paseo Fork (`QSothoth/paseo`) — Maintenance & Deployment Guide

This fork (`QSothoth/paseo`, branch `custom/vps-paseo-fixes`) maintains a lean, linear, easy-to-rebase server patch stack for running Paseo cleanly on a 4 GB RAM Linux VPS with Antigravity (`agy`), Claude Code, and Codex.

Base upstream commit: `getpaseo/paseo` `main` (`984e2ea5`, `v0.17.1` + `#10428` Antigravity restart history).

## Patch Stack (All Linear Commits on `custom/vps-paseo-fixes`)

| # | Scope | Upstream Ref | What It Fixes |
| --- | --- | --- | --- |
| 1 | `plugin-provider.ts` | [getpaseo/paseo#10412](https://github.com/getpaseo/paseo/issues/10412) | Allow unconnected command-backed plugin providers (Antigravity, Muse) to lazily probe `session.list` during Import Session without erroring on missing binaries. |
| 2 | `acp-internal/connection.ts` | [getpaseo/paseo#10413](https://github.com/getpaseo/paseo/issues/10413) | Filter ACP `session/list` results by `input.query` across `nextCursor` pages before applying `input.limit`. |
| 3 | `antigravity-provider` | [getpaseo/paseo#10414](https://github.com/getpaseo/paseo/issues/10414) | Exclude recurring `CronExpression` schedules and long one-shot timers (`DurationSeconds > 30`) from keeping an ACP turn stuck in `running`. |
| 4 | `antigravity-provider` | [getpaseo/paseo#10415](https://github.com/getpaseo/paseo/issues/10415) | Raise ACP `startupTimeoutMs` to `30_000`, coalesce/cache `status()` probes, and surface real startup/auth errors. |
| 5 | `acp-internal/connection.ts` | [getpaseo/paseo#10416](https://github.com/getpaseo/paseo/issues/10416) | Fall back to session active defaults when resuming an ACP session whose saved `model`/`thinkingOption` ID was retired. |
| 6 | `daemon-client.ts`, `plugin-process.ts` | [getpaseo/paseo#9363](https://github.com/getpaseo/paseo/pull/9363) | Disable pointless 10s heartbeat pings on IPC plugin connections and exit orphan plugins when daemon IPC drops. |
| 7 | `protocol`, `server` idle cleanup | [getpaseo/paseo#8964](https://github.com/getpaseo/paseo/pull/8964) | Make `daemon.idleRuntimeCleanupMinutes` configurable (5–1440 min; recommend `15` on 4 GB VPS) and release read-only history loads 2 min after the last read so mobile peeking doesn't pin 200 MB runtimes for an hour. |
| 8 | `codex-app-server-agent.ts`, `app-server-transport.ts` | [getpaseo/paseo#9957](https://github.com/getpaseo/paseo/pull/9957) | Allow idle runtime cleanup to release disposed Codex transports instead of timing out on `thread/loaded/list`. |
| 9 | `claude/agent.ts`, `create-agent-mode.ts` | VPS root host safeguard | When the daemon runs as `root` (`uid 0`), disable `allowDangerouslySkipPermissions` (which Claude Code CLI rejects under root), hide `bypassPermissions` from the mode catalog, and normalize legacy `bypassPermissions` requests to `auto`. Non-root behavior is unchanged. |

## Host-Level Tuning for a 4 GB RAM Linux VPS

### 1. Kernel Swap Balance (`/etc/sysctl.d/99-zz-vps-balance.conf`)

```ini
vm.swappiness = 10
```

Apply immediately: `sysctl -p /etc/sysctl.d/99-zz-vps-balance.conf`. Keeps Paseo Daemon and active sessions in physical RAM instead of thrashing to disk swap.

### 2. Balanced Systemd Unit (`/etc/systemd/system/paseo.service`)

```ini
[Service]
Environment=MALLOC_ARENA_MAX=2
Environment=MALLOC_MMAP_THRESHOLD_=131072
ReadWritePaths=/var/lib/paseo /opt/opend-us-options /opt/dsh-workspace /root
MemoryLow=256M
MemoryHigh=2600M
MemoryMax=3000M
MemorySwapMax=2048M
OOMPolicy=continue
TasksMax=256
```

- `MemoryLow=256M` protects Paseo's working set from routine reclaim.
- `MemoryHigh=2600M` avoids throttling normal single-job peaks (~1.7–2.2 GB) that previously froze Paseo's event loop under `1800M`.
- `MemoryMax=3000M` + `OOMPolicy=continue` caps runaway workloads while leaving ~800–1000 MB for SSH, VS Code, and other host services without killing the Paseo daemon.

### 3. Recommended `config.json` Setting (Once Upgraded to This Fork)

Inside `$PASEO_HOME/config.json` under `"daemon"`:

```json
"idleRuntimeCleanupMinutes": 15
```

## Routine Upgrade & Deployment Workflow

### 1. Rebase onto Newer Upstream Paseo

```bash
cd /root/paseo-fork
git fetch upstream main --tags
git checkout main && git merge --ff-only upstream/main
git checkout custom/vps-paseo-fixes
git rebase main
# Commits already merged upstream are skipped automatically by git rebase.
git push --force-with-lease origin custom/vps-paseo-fixes
git push origin main
```

### 2. Build, Test, and Stage on the VPS (Lean Server-Only Build)

```bash
cd /root/paseo-fork
bash scripts/vps-build-server.sh --test --out /opt/paseo-custom-dist --install /opt/paseo-app-next
```

This builds only the 7 server packages + built-in plugins inside a temporary directory (skipping Electron / Expo / Playwright), runs targeted Vitest unit tests, packs `.tgz` tarballs, and installs a ready-to-swap runtime at `/opt/paseo-app-next` **without touching the running `/opt/paseo-app`**.

### 3. Zero-Drama Atomic Swap & Instant Rollback

Run only when active agent jobs are idle:

```bash
systemctl stop paseo.service
mv /opt/paseo-app /opt/paseo-app.prev
mv /opt/paseo-app-next /opt/paseo-app
systemctl start paseo.service
systemctl status paseo.service --no-pager

# Instant rollback if needed:
# systemctl stop paseo.service && mv /opt/paseo-app /opt/paseo-app.bad && mv /opt/paseo-app.prev /opt/paseo-app && systemctl start paseo.service
```
