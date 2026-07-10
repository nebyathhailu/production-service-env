#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${1:-}"

if [ -z "$IMAGE_TAG" ]; then
  echo "Usage: ./scripts/deploy.sh sha-<short-commit-hash>"
  echo "Example: ./scripts/deploy.sh sha-a1b2c3d"
  exit 1
fi

if [[ "$IMAGE_TAG" == "latest" ]]; then
  echo "Refusing to deploy tag 'latest' - use a commit-pinned sha-<hash> tag."
  exit 1
fi

export IMAGE_TAG
export APP_NAME="${APP_NAME:-$(basename "$PWD")}"

if [ -z "${DOCKERHUB_USERNAME:-}" ]; then
  echo "Missing DOCKERHUB_USERNAME"
  exit 1
fi

echo "Deploying ${APP_NAME} using image tag: ${IMAGE_TAG}"

docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d --remove-orphans --wait
docker compose -f docker-compose.prod.yml ps
