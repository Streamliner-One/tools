# Project Teleport

> Deploy or replicate the full OpenClaw + Mem0 self-hosted stack to any machine.

---

## 🚀 Running a Restore (Mel Miles mode)

### What you need before starting

| Item | Where to find it |
|------|-----------------|
| Backup archive (`.tar.gz.gpg`) | Google Drive — download to server first |
| Backup decryption key | `~/.openclaw/.backup-key` on current mel, or 1Password (emergency) |
| GitHub token | 1Password → `github` → token field |
| Telegram bot token | Create a dedicated test/transit bot via @BotFather first |

### The command

```bash
bash teleport-restore.sh \
  --backup /root/openclaw-backup-latest.tar.gz.gpg \
  --key-file /root/.backup-key \
  --github-token <token> \
  --user alex \
  --telegram-token <bot-token>
```

### After the script finishes

1. **SSH in** as `alex` and change the temp password: `passwd`
2. **Message your bot** on Telegram → you'll get a pairing request
3. **Approve pairing**: `openclaw pairing list` → `openclaw pairing approve`
4. **Verify** the agent responds in Telegram
5. **Harden** (once everything works): `bash ~/.openclaw/workspace/streamliner/teleport/harden.sh`

> If you passed `--telegram-token`, the gateway starts automatically.
> If not, update `~/.openclaw/openclaw.json` → `channels.telegram.token`, then `systemctl --user start openclaw-gateway`.

---

## What It Is

Teleport is the mechanism for moving or cloning the entire Streamliner assistant stack — OpenClaw runtime, Mem0 (Qdrant + Neo4j), Tools Config Server, hooks, cron jobs, and agent identity — onto a new machine. It has two modes:

| Mode | Use case | Includes memories? | Includes credentials? |
|------|----------|-------------------|----------------------|
| **Mel Miles** | Alex's own machines (new VPS, Mac Mini, etc.) | ✅ Yes (full restore) | ✅ Yes (encrypted) |
| **Client installs** | New client deployments | ❌ No | ❌ No (they add their own) |

---

## Architecture: Four Layers

| Layer | Contents |
|-------|----------|
| **Software** | OpenClaw, Tools Config Server, Docker images (Qdrant, Neo4j) |
| **Configuration** | `openclaw.json`, credentials, hooks, cron, systemd |
| **Personal data** | Qdrant vectors, Neo4j graph, SQLite history, workspace files |
| **Identity** | `SOUL.md`, `IDENTITY.md`, `USER.md`, `AGENTS.md`, `HEARTBEAT.md`, `TOOLS.md` |

Mel Miles restores all four. Client installs deliver layer 1 only, then guide the client through layers 2–4.

---

## Delivery URLs

| Component | URL | Status |
|-----------|-----|--------|
| Tools Config Server installer | `curl https://tools.streamliner.one \| bash` | ✅ Live |
| Full stack installer (Teleport) | `curl https://teleport.streamliner.one \| bash` | 🔲 Not yet |

---

## Script Inventory

| Script | Location | Status | Purpose |
|--------|----------|--------|---------|
| `install.sh` | `Streamliner-One/tools` → `tools.streamliner.one` | ✅ Done | Installs Tools Config Server |
| `teleport-restore.sh` | `teleport/` folder (local only) | 🟡 Draft (468 lines) | Mel Miles full restore — needs phase 9.5 (tools server install) wired in |
| `setup-client.sh` | — | 🔲 Not built | Parameterized clean install for clients |
| `fire-drill.sh` | — | 🔲 Not built | Automated test cycle on fresh VPS |

### Script sequencing (full stack)
```
base deps → OpenClaw → Mem0 stack (Qdrant + Neo4j) → restore data
  → tools server install [phase 9.5, missing] → agent config → verify
```

---

## Phase Status

### ✅ Phase 1 — Tools Server delivery (COMPLETE)
- GitHub repo renamed `Streamliner-One/install` → `Streamliner-One/tools`
- Netlify domain `install.streamliner.one` → `tools.streamliner.one`
- `curl https://tools.streamliner.one | bash` live and serving `application/x-sh`
- All URL references updated across `tools`, `tools-packages`, `tools-config-server`
- 33/33 integrations healthy post-install

### 🟡 Phase 2 — Full stack installer (IN PROGRESS)
- `teleport-restore.sh` drafted, covers phases 1–10 for Mel Miles mode
- Missing: phase 9.5 (tools server install), GitHub repo, Netlify site, delivery URL
- Client path (`setup-client.sh`) not started

### 🔲 Phase 3 — Client installer
- Parameterized templates
- `setup-client.sh` — guided onboarding, no personal data

### 🔲 Phase 4 — Fire drills
- `fire-drill.sh` — spin up fresh VPS, run full install, verify, destroy

---

## What Needs To Be Done (Manually)

### GitHub (Alex does this)
1. Create new **public** repo: `Streamliner-One/teleport`
   - Public so the install script is fetchable without auth
   - Description: *"Full-stack OpenClaw + Mem0 installer — Project Teleport"*
   - Initialize with README (will be replaced)

### Netlify (Alex does this)
2. Create new Netlify site from `Streamliner-One/teleport` repo
   - Site serves the root file (same pattern as `tools.streamliner.one`)
   - Add custom domain: `teleport.streamliner.one`
3. Add DNS record in Netlify DNS:
   - Type: `CNAME`, Name: `teleport`, Value: `<new-netlify-site>.netlify.app`

### Then Mel takes over
4. Push `teleport-restore.sh` (renamed to entry script) to the new repo
5. Wire in phase 9.5 (tools server install)
6. Test end-to-end

---

## Backup
- Nightly backup capsule (~1.2MB) generated and uploaded to Google Drive
- Script: `backup-mem0.sh`
- Payload: Qdrant snapshot + Neo4j export + `openclaw.json` + hooks, encrypted

---

*Last updated: 2026-03-13*
