#!/usr/bin/env bash
# Runs on the Jenkins agent. Rolls the new image out ONE instance at a time:
#   deregister from ALB (drain) -> replace container -> local health check -> register -> wait healthy
# If anything fails, the instance is restored to the previous container and the pipeline stops,
# so the remaining instance(s) keep serving the old version.
set -euo pipefail

: "${APP_HOSTS:?}" "${TARGET_GROUP_ARN:?}" "${SSH_USER:?}" "${ECR_URI:?}" "${IMAGE_TAG:?}" "${AWS_REGION:?}" "${DATABASE_URL:?}" "${PAYLOAD_SECRET:?}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15"

instance_id() {
  aws ec2 describe-instances \
    --filters "Name=private-ip-address,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

register()   { aws elbv2 register-targets   --target-group-arn "$TARGET_GROUP_ARN" --targets "Id=$1"
               aws elbv2 wait target-in-service --target-group-arn "$TARGET_GROUP_ARN" --targets "Id=$1"; }
deregister() { aws elbv2 deregister-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "Id=$1"
               aws elbv2 wait target-deregistration --target-group-arn "$TARGET_GROUP_ARN" --targets "Id=$1"; }

for HOST in $APP_HOSTS; do
  IID=$(instance_id "$HOST")
  echo "=== $HOST ($IID) ==="

  # Never take an instance out unless at least one OTHER target is healthy.
  OTHERS=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy' && Target.Id!='$IID'])" --output text)
  if [ "$OTHERS" -lt 1 ]; then
    echo "ERROR: no other healthy target in the group - refusing to drain $IID"; exit 1
  fi

  echo "-> draining from ALB"
  deregister "$IID"

  echo "-> deploying $IMAGE_TAG"
  scp $SSH_OPTS deploy/host-deploy.sh "${SSH_USER}@${HOST}:/tmp/host-deploy.sh"
  if ! printf 'DATABASE_URL=%s\nPAYLOAD_SECRET=%s\n' "$DATABASE_URL" "$PAYLOAD_SECRET" \
      | ssh $SSH_OPTS "${SSH_USER}@${HOST}" \
        "ECR_URI='${ECR_URI}' IMAGE_TAG='${IMAGE_TAG}' AWS_REGION='${AWS_REGION}' bash /tmp/host-deploy.sh deploy"; then
    echo "ERROR: deploy failed on $HOST; host script restored the previous container. Re-registering."
    register "$IID" || true
    exit 1
  fi

  echo "-> registering back to ALB"
  register "$IID"
  echo "=== $HOST done ==="
done

echo "Rolling deploy of $IMAGE_TAG complete."
