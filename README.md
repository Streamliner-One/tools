# OpenClaw Tools Config Server

Self-hosted credential vault, service health dashboard, live query runner, and TOOLS.md generator for AI agent infrastructure.

```bash
curl https://tools.streamliner.one | bash
```

Sets up Node.js, downloads the server, installs dependencies, creates a systemd service, and prints your access URL and password. Tested on Ubuntu 22.04 / 24.04.

---

## What it does

| Feature | Description |
|---------|-------------|
| **Credential vault** | Store and manage API keys, tokens, and OAuth configs in one place |
| **Live validation** | Test button per service — confirms keys work before your agent tries them |
| **Health dashboard** | All services at a glance with status, last checked, and error details |
| **Query runner** | Ready-to-use curl examples for every service, executable server-side |
| **TOOLS.md generator** | Auto-generates a human-readable credential reference for AI agents |
| **Intent router** | Lightweight `router.json` maps agent intents to the right service — no guessing |
| **Rate limit resilience** | Configurable retry + exponential backoff when providers return 429 |
| **E2E verification** | `verify-integrations.sh` tests every credential end-to-end: schema → router → live API probe |
| **Update center** | One-click update from the dashboard — no SSH required |

---

## Supported services

| Category | Services |
|----------|----------|
| **AI** | OpenAI, Anthropic, Moonshot (Kimi), Gemini (Google), OpenRouter |
| **Search** | Brave Search, Perplexity, NewsAPI |
| **Productivity** | Notion, Notion (Enhanced), Todoist, Google Workspace |
| **Knowledge** | Obsidian Sync (Headless), Readwise |
| **Travel** | Amadeus, Duffel, Aviationstack |
| **Voice** | ElevenLabs, VAPI |
| **Support** | Groove HQ |
| **Automation** | n8n |
| **Vector DB** | Pinecone |
| **Messaging** | Telegram |
| **Location** | Google Places |
| **Finance** | Open Exchange Rates, Stripe |
| **Logistics** | 17TRACK |
| **Health** | Oura |
| **Security** | 1Password |
| **Audio** | OpenAI Whisper |
| **Weather** | Open-Meteo (no key needed) |
| **Image** | Nano Banana Pro |
| **Memory** | Mem0 |
| **Utilities** | Public Holidays (Nager.Date) |
| **Developer** | GitHub, Supabase, Resend |

---

## Security model

- Password protected (bcrypt hashed)
- HTTP-only session cookies
- Helmet security headers
- Self-signed TLS option (`--https`)
- **Bind to Tailscale recommended** — keeps the dashboard off the public internet
- Temporal access mode (`--temp 30`) — auto-shuts down after N minutes for safe temporary exposure

---

## Manual channel selection

```bash
curl https://tools.streamliner.one | bash -s -- --channel latest
```

## Channels

| Channel | Version |
|---------|---------|
| `stable` | 1.0.0 |
| `latest` | 1.0.0 |

Channel manifest: [`versions.json`](./versions.json)

---

## For Streamliner One clients

Pre-installed on provisioned VPS instances. Clients configure their own keys without SSH or VNC access. Rate limit handling keeps automations running during provider outages. TOOLS.md auto-generated for AI agent documentation compliance.
