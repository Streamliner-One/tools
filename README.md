# Streamliner One Install

Universal installer entrypoint for Streamliner One tooling.

## Purpose
This repo is the single `/install` endpoint used to bootstrap supported products.

Current target:
- Tools Config Server

## Planned URL
```bash
curl -fsSL https://install.streamliner.one | bash
```

## Repo Layout
- `install.sh` — bootstrap installer
- `versions.json` — stable/latest release channels
- `artifacts/` — optional release bundles

## Notes
- Keep this repo simple and stable.
- Backward compatibility matters: old installer URLs should continue to work.
