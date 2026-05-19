#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Ensure the agent knows about the gbrain shared-brain MCP server. Idempotent:
# only adds the entry if absent, so manual edits (renaming, disabling, a
# co-founder's tweaks) survive every redeploy. The DB URL is written as the
# literal "${GBRAIN_DATABASE_URL}" placeholder — hermes expands it from the
# container env at config load, so the Supabase secret is never written to the
# /data volume in plaintext.
python - <<'PY' || true
import sys
try:
    import yaml
except Exception:
    sys.exit(0)
p = "/data/.hermes/config.yaml"
try:
    with open(p) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    cfg = {}
if not isinstance(cfg, dict):
    cfg = {}
servers = cfg.setdefault("mcp_servers", {})
if not isinstance(servers, dict):
    print("[start.sh] mcp_servers is not a mapping; leaving config untouched")
elif "gbrain" in servers:
    print("[start.sh] mcp_servers.gbrain already present; leaving as-is")
else:
    servers["gbrain"] = {
        "command": "gbrain",
        "args": ["serve"],
        "env": {
            "GBRAIN_DATABASE_URL": "${GBRAIN_DATABASE_URL}",
            "GBRAIN_DIRECT_DATABASE_URL": "${GBRAIN_DIRECT_DATABASE_URL}",
            "OPENAI_API_KEY": "${OPENAI_API_KEY}",
        },
    }
    with open(p, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
    print("[start.sh] seeded mcp_servers.gbrain into config.yaml")
PY

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

exec python /app/server.py
