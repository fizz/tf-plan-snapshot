#!/usr/bin/env bash
# tf-plan-snapshot.sh — snapshot the EBS volumes that a saved Terraform plan
# deletes, before the apply runs.
#
# Usage: tf-plan-snapshot.sh --plan-json <file> --region <region> [--apply] [--tag-run <id>]
#
# A volume is at risk when the plan deletes it (replace counts) as:
#   - an aws_ebs_volume
#   - a volume attached to an aws_instance that the plan deletes
# Without --apply the script lists those volumes and changes nothing.
#
# Fails closed: a plan file it cannot read, or a volume it cannot snapshot, exits
# non-zero, so a workflow step that runs before the apply stops the apply.
set -euo pipefail

PLAN_JSON="" REGION="" APPLY=false RUN_TAG="${GITHUB_RUN_ID:-manual}"
while [ $# -gt 0 ]; do
  case "$1" in
    --plan-json) PLAN_JSON="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --apply)     APPLY=true; shift ;;
    --tag-run)   RUN_TAG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -s "$PLAN_JSON" ] || { echo "error: --plan-json is missing or empty" >&2; exit 2; }
[ -n "$REGION" ]    || { echo "error: --region is required" >&2; exit 2; }

jq -e '.format_version' "$PLAN_JSON" >/dev/null \
  || { echo "error: $PLAN_JSON is not 'terraform show -json' output" >&2; exit 1; }

# "address<TAB>id" for each deleted volume and each deleted instance.
mapfile -t VOLUMES < <(jq -r '
  .resource_changes[]?
  | select(.type == "aws_ebs_volume" and (.change.actions | index("delete")))
  | [.address, .change.before.id] | @tsv' "$PLAN_JSON")
mapfile -t INSTANCES < <(jq -r '
  .resource_changes[]?
  | select(.type == "aws_instance" and (.change.actions | index("delete")))
  | [.address, .change.before.id] | @tsv' "$PLAN_JSON")

declare -A REASON=()
for row in "${VOLUMES[@]}"; do
  addr="${row%%$'\t'*}"; id="${row#*$'\t'}"
  REASON[$id]="$addr is deleted"
done
for row in "${INSTANCES[@]}"; do
  addr="${row%%$'\t'*}"; iid="${row#*$'\t'}"
  attached="$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=attachment.instance-id,Values=$iid" \
    --query 'Volumes[].VolumeId' --output text)"
  for vid in $attached; do
    [ -n "${REASON[$vid]:-}" ] || REASON[$vid]="attached to $addr ($iid), which is deleted"
  done
done

if [ "${#REASON[@]}" -eq 0 ]; then
  echo "No volume at risk in this plan."
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "snapshot_ids=" >> "$GITHUB_OUTPUT"
  exit 0
fi

SNAPS=()
for vid in "${!REASON[@]}"; do
  if [ "$APPLY" != true ]; then
    echo "would snapshot $vid: ${REASON[$vid]}"
    continue
  fi
  sid="$(aws ec2 create-snapshot --region "$REGION" --volume-id "$vid" \
    --description "tf-plan-snapshot before apply (run $RUN_TAG): ${REASON[$vid]}" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=pre-apply-$vid},{Key=tf-plan-snapshot,Value=$RUN_TAG}]" \
    --query SnapshotId --output text)"
  echo "snapshot $sid of $vid: ${REASON[$vid]}"
  SNAPS+=("$sid")
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "snapshot_ids=${SNAPS[*]:-}" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Volumes at risk in this plan"
    for vid in "${!REASON[@]}"; do echo "- \`$vid\`: ${REASON[$vid]}"; done
    [ "${#SNAPS[@]}" -gt 0 ] && echo && echo "Snapshots: ${SNAPS[*]}"
  } >> "$GITHUB_STEP_SUMMARY"
fi
