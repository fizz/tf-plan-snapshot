# tf-plan-snapshot

A GitHub Action that takes EBS snapshots of the volumes a saved Terraform plan deletes. Run it after `terraform plan -out` and before `terraform apply`.

A Terraform plan shows a volume replacement as one line among the other replacements. When the volume holds state (a database, a key, a node identity), the apply deletes that state, and the new volume is empty. This action reads the plan, finds each volume at risk, and takes a snapshot of it first.

A volume is at risk when the plan deletes it, and a replacement counts as a delete:

- an `aws_ebs_volume`
- a volume attached to an `aws_instance`

The action fails closed. If it cannot read the plan, or a snapshot fails, the step fails and the apply does not run.

## Usage

```yaml
- run: terraform plan -out=tfplan
  working-directory: environments/prod

- uses: fizz/tf-plan-snapshot@v1
  with:
    plan: tfplan
    working-directory: environments/prod
    region: us-east-1

- run: terraform apply tfplan
  working-directory: environments/prod
```

The job needs AWS credentials that allow `ec2:DescribeVolumes`, `ec2:CreateSnapshot` and `ec2:CreateTags`.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `plan` | Path to the saved plan file | required |
| `working-directory` | Directory to run `terraform show` in | `.` |
| `region` | AWS region of the volumes | required |
| `apply` | Take the snapshots. Any other value only lists the volumes at risk | `true` |

## Outputs

| Name | Description |
|------|-------------|
| `snapshot_ids` | Space-separated snapshot IDs. Empty when no volume was at risk |

Each snapshot has the tags `Name=pre-apply-<volume-id>` and `tf-plan-snapshot=<run id>`. The action does not delete snapshots. Use a Data Lifecycle Manager policy or a cleanup job to expire them.

## Run it locally

```bash
terraform show -json tfplan > plan.json
./tf-plan-snapshot.sh --plan-json plan.json --region us-east-1           # list only
./tf-plan-snapshot.sh --plan-json plan.json --region us-east-1 --apply   # take the snapshots
```

The script needs bash 4 or later and `jq`.

## License

MIT
