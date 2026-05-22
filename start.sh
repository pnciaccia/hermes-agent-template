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

# Ensure the agent knows about the gbrain shared-brain MCP server, AND that
# its required env keys are present on every boot. First-run: seed the full
# entry. Subsequent boots: reconcile the REQUIRED keys (don't blow away
# manual additions). The required-key reconciliation matters because new
# required env vars (e.g., GBRAIN_SOURCE added 2026-05-22 to prevent
# silent-source-fallback to the empty `default` source) otherwise never
# propagate to a /data volume that already has a seeded config.yaml.
# DB URLs / source / API key are written as literal "${VAR}" placeholders —
# hermes expands them from the container env at config load, so secrets are
# never written to the /data volume in plaintext.
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

REQUIRED_ENV = {
    "GBRAIN_DATABASE_URL":        "${GBRAIN_DATABASE_URL}",
    "GBRAIN_DIRECT_DATABASE_URL": "${GBRAIN_DIRECT_DATABASE_URL}",
    "GBRAIN_SOURCE":              "${GBRAIN_SOURCE}",
    "OPENAI_API_KEY":             "${OPENAI_API_KEY}",
}

if not isinstance(servers, dict):
    print("[start.sh] mcp_servers is not a mapping; leaving config untouched")
else:
    existing = servers.get("gbrain")
    if not isinstance(existing, dict):
        servers["gbrain"] = {
            "command": "gbrain",
            "args": ["serve"],
            "env": dict(REQUIRED_ENV),
        }
        with open(p, "w") as f:
            yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
        print("[start.sh] seeded mcp_servers.gbrain into config.yaml")
    else:
        env = existing.setdefault("env", {})
        if not isinstance(env, dict):
            env = {}
            existing["env"] = env
        changed = []
        for k, v in REQUIRED_ENV.items():
            if env.get(k) != v:
                env[k] = v
                changed.append(k)
        if changed:
            with open(p, "w") as f:
                yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
            print(f"[start.sh] reconciled mcp_servers.gbrain.env: {','.join(changed)}")
        else:
            print("[start.sh] mcp_servers.gbrain.env already in sync")
PY

# Validate LLM_MODEL — Pattern B (admin UI / .env is the source of truth).
#
# At boot we read whatever model is in /data/.hermes/.env (the admin-dashboard
# "save & restart" flow writes to this file, and server.py:464-469 reads it
# preferentially over process env when spawning the gateway). We validate the
# value against OpenRouter's actual model catalog and only overwrite if it's
# bad — gracefully falling back to SAFE_LLM_DEFAULT so the bot stays usable
# rather than wedged on a deprecated/typo model id.
#
# Order of precedence for the boot-time value:
#   1. LLM_MODEL line in /data/.hermes/.env  (the admin UI's latest choice)
#   2. LLM_MODEL in process env              (Doppler seed, if anyone still pushes one)
#   3. SAFE_LLM_DEFAULT                      (last-resort known-good fallback)
#
# To change the model day-to-day: open the admin dashboard, pick from the
# selector, save & restart. The change persists across container restarts
# because .env survives on the persistent volume. If you pick something
# OpenRouter has deprecated (rare), the next container boot logs a loud
# WARN and replaces it with SAFE_LLM_DEFAULT — bot keeps working.
SAFE_LLM_DEFAULT="anthropic/claude-sonnet-4.6"
python3 - <<PY
import os, json, sys, urllib.request

default  = "${SAFE_LLM_DEFAULT}"
env_path = "/data/.hermes/.env"
key      = (os.environ.get("OPENROUTER_API_KEY") or "").strip()

def log(m): sys.stderr.write(m + "\\n")

# 1. Read current LLM_MODEL from .env (admin dashboard's persisted choice)
current, source = None, None
try:
    for line in open(env_path).read().splitlines():
        if line.startswith("LLM_MODEL="):
            current = line[len("LLM_MODEL="):].strip()
            source  = ".env"
            break
except FileNotFoundError:
    pass

# 2. Fall back to process env (legacy Doppler seed)
if not current:
    current = (os.environ.get("LLM_MODEL") or "").strip()
    source  = "process env (Doppler seed)" if current else None

# 3. Last resort: hard-coded safe default
if not current:
    current = default
    source  = "SAFE_LLM_DEFAULT"

# 4. Validate against OpenRouter (skip cleanly if unreachable)
final = current
if not key:
    log(f"[start.sh] no OPENROUTER_API_KEY — skipping validation; keeping {current} (source: {source})")
else:
    try:
        req = urllib.request.Request("https://openrouter.ai/api/v1/models",
                                     headers={"Authorization": "Bearer " + key})
        ids = {m["id"] for m in json.load(urllib.request.urlopen(req, timeout=10))["data"]}
        if current in ids:
            log(f"[start.sh] LLM_MODEL={current} validated against OpenRouter catalog ({len(ids)} models) [source: {source}]")
        else:
            log(f"[start.sh] WARN: LLM_MODEL={current} NOT in OpenRouter catalog (source: {source}). Falling back to {default}.")
            log(f"[start.sh]       Change model via the Hermes admin dashboard. See org/hermes-deploy.md.")
            final = default
    except Exception as e:
        log(f"[start.sh] WARN: could not reach OpenRouter to validate ({e}); keeping {current} (source: {source})")

# 5. Ensure .env has the final value (idempotent; preserves every other line)
try:
    lines = open(env_path).read().splitlines()
except FileNotFoundError:
    lines = []
out, found = [], False
for line in lines:
    if line.startswith("LLM_MODEL="):
        if not found:
            out.append(f"LLM_MODEL={final}"); found = True
    else:
        out.append(line)
if not found:
    out.append(f"LLM_MODEL={final}")
new_content = "\\n".join(out) + ("\\n" if out else "")
try:
    if open(env_path).read() == new_content:
        log(f"[start.sh] /data/.hermes/.env LLM_MODEL already {final}; no write needed")
    else:
        with open(env_path, "w") as f: f.write(new_content)
        os.chmod(env_path, 0o600)
        log(f"[start.sh] /data/.hermes/.env LLM_MODEL set to {final}")
except FileNotFoundError:
    with open(env_path, "w") as f: f.write(new_content)
    os.chmod(env_path, 0o600)
    log(f"[start.sh] /data/.hermes/.env created with LLM_MODEL={final}")
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
