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

# Validate LLM_MODEL against OpenRouter's actual model catalog. Recurring
# footgun: setting LLM_MODEL to a deprecated alias (e.g. "claude-sonnet-latest"
# or anything with a "~" prefix) makes every chat fail with HTTP 400 from
# OpenRouter — and you don't notice until someone DMs the bot. We check once
# at boot. If the configured model isn't in the catalog, fall back to a known-
# good default so the bot stays *usable* rather than wedged. A different model
# is a worse outcome than a wedged production bot only in spec-compliance, not
# in practice — the loud log line and the brain page (org/hermes-deploy.md)
# tell the operator what happened.
SAFE_LLM_DEFAULT="anthropic/claude-sonnet-4.6"
VALIDATED_LLM_MODEL=$(SAFE_LLM_DEFAULT="$SAFE_LLM_DEFAULT" python3 - <<'PY'
import os, json, sys, urllib.request
model = (os.environ.get('LLM_MODEL') or '').strip()
default = os.environ['SAFE_LLM_DEFAULT']
key = (os.environ.get('OPENROUTER_API_KEY') or '').strip()
def log(m): sys.stderr.write(m + "\n")
if not model:
    log(f"[start.sh] WARN: LLM_MODEL empty — using {default}")
    print(default); sys.exit(0)
if not key:
    log(f"[start.sh] no OPENROUTER_API_KEY — skipping validation; keeping {model}")
    print(model); sys.exit(0)
try:
    req = urllib.request.Request(
        'https://openrouter.ai/api/v1/models',
        headers={'Authorization': 'Bearer ' + key}
    )
    ids = {m['id'] for m in json.load(urllib.request.urlopen(req, timeout=10))['data']}
    if model in ids:
        log(f"[start.sh] LLM_MODEL={model} validated against OpenRouter catalog ({len(ids)} models)")
        print(model)
    else:
        log(f"[start.sh] WARN: LLM_MODEL={model} NOT in OpenRouter catalog. Falling back to {default}")
        log(f"[start.sh]       See org/hermes-deploy.md for the LLM_MODEL gotcha.")
        print(default)
except Exception as e:
    log(f"[start.sh] WARN: could not validate LLM_MODEL ({e}); keeping {model} as-is")
    print(model)
PY
)
export LLM_MODEL="$VALIDATED_LLM_MODEL"

# Reconcile /data/.hermes/.env so the gateway sees the validated value.
# server.py:464-469 reads .env preferentially over process env when spawning
# the gateway ("# .env values take priority over Railway env vars"), and
# server.py:474 writes config.yaml's model.default from read_env(ENV_FILE)
# only — not from os.environ. So a stale LLM_MODEL line in .env (left behind
# by an earlier admin-dashboard form submission, or any prior bad value) will
# shadow even a freshly-set Doppler/Railway env var indefinitely. This is
# what kept "claude-sonnet-latest" wedging the bot across multiple redeploys
# despite Doppler being correct. We rewrite the LLM_MODEL line idempotently;
# every other line in .env is preserved verbatim.
LLM_MODEL="$VALIDATED_LLM_MODEL" python3 - <<'PY'
import os
p = "/data/.hermes/.env"
model = os.environ["LLM_MODEL"]
try:
    lines = open(p).read().splitlines()
except FileNotFoundError:
    lines = []
out, found = [], False
for line in lines:
    if line.startswith("LLM_MODEL="):
        if not found:
            out.append(f"LLM_MODEL={model}"); found = True
        # drop any duplicate LLM_MODEL lines (defensive)
    else:
        out.append(line)
if not found:
    out.append(f"LLM_MODEL={model}")
with open(p, "w") as f:
    f.write("\n".join(out) + ("\n" if out else ""))
os.chmod(p, 0o600)
print(f"[start.sh] /data/.hermes/.env LLM_MODEL reconciled to {model}")
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
