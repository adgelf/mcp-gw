#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/deploy/compose/docker-compose.yaml"
GITHUB_COMPOSE_FILE="$ROOT_DIR/deploy/compose/docker-compose.github-mcp.yaml"
BROKER_COMPOSE_FILE="$ROOT_DIR/deploy/compose/docker-compose.broker.yaml"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/compose/.env.example}"

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$GITHUB_COMPOSE_FILE" \
  --profile github-mcp config >/dev/null
BROKER_GATEWAY_CONFIG="$ROOT_DIR/gateway/agentgateway/local-broker.yaml" \
  LOCAL_BROKER_SIGNING_JWKS_DIR="$ROOT_DIR/deploy/compose" \
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -f "$BROKER_COMPOSE_FILE" \
  config >/dev/null
