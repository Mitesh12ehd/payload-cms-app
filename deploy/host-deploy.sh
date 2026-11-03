#!/usr/bin/env bash
# Runs ON the EC2 instance. Usage: bash /tmp/host-deploy.sh <deploy|migrate>
# Secrets (DATABASE_URL=..., PAYLOAD_SECRET=...) are piped in on stdin by Jenkins.
# Needs on the instance: docker, aws cli, curl, and an instance profile with ECR pull access.
set -euo pipefail

MODE="${1:?usage: deploy|migrate}"
: "${ECR_URI:?}" "${IMAGE_TAG:?}" "${AWS_REGION:?}"

APP=payload-cms
PORT=3000
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"

# Secrets arrive on stdin from Jenkins -> root-only file on tmpfs, deleted on exit.
ENV_FILE="$(mktemp /dev/shm/payload-env.XXXXXX)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE"
[ -s "$ENV_FILE" ] || { echo "ERROR: no secrets received on stdin"; exit 1; }
echo "NODE_ENV=production" >> "$ENV_FILE"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URI" >/dev/null

if [ "$MODE" = "migrate" ]; then
  docker pull "${ECR_URI}:${IMAGE_TAG}-migrate"
  docker run --rm --env-file "$ENV_FILE" "${ECR_URI}:${IMAGE_TAG}-migrate"
  exit 0
fi

# ---- deploy ----
docker pull "${ECR_URI}:${IMAGE_TAG}"

HAD_PREV=0
if docker inspect "$APP" >/dev/null 2>&1; then
  HAD_PREV=1
  docker rm -f "${APP}-prev" >/dev/null 2>&1 || true
  docker stop -t 30 "$APP"                 # graceful shutdown (instance is already drained from the ALB)
  docker rename "$APP" "${APP}-prev"       # keep the old container so we can roll back instantly
fi

docker run -d --name "$APP" --init --restart unless-stopped \
  -p ${PORT}:3000 \
  --env-file "$ENV_FILE" \
  --log-opt max-size=10m --log-opt max-file=5 \
  "${ECR_URI}:${IMAGE_TAG}"

rollback() {
  echo "!!! new container unhealthy - rolling back"
  docker logs --tail 100 "$APP" || true
  docker rm -f "$APP" >/dev/null 2>&1 || true
  if [ "$HAD_PREV" = 1 ]; then
    docker rename "${APP}-prev" "$APP"
    docker start "$APP"
  fi
  exit 1
}

echo "waiting for $HEALTH_URL ..."
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "healthy after $((i*5))s"
    docker image prune -f >/dev/null
    exit 0
  fi
  sleep 5
done
rollback
