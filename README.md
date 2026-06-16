# AWS Infrastructure Handover - Data Gathering Scripts

PowerShell scripts to gather AWS infrastructure information and export to CSV for customer handover documentation.

## Prerequisites

- **AWS CLI v2** installed and configured (`aws configure`)
- **PowerShell 5.1+** (Windows) or PowerShell Core 7+
- AWS credentials with read access to:
  - EC2 (instances, volumes, security groups, instance types)
  - AWS Backup (plans, tags)

## Scripts

| Script | Output File | Description |
|--------|-------------|-------------|
| `gather-aws-info.ps1` | `output/ec2-instances.csv` | EC2 instance list (Name, Private IP, Instance Type, Environment tag) |
| `gather-server-specs.ps1` | `output/ec2-server-specs.csv` | Server specifications (Name, Platform, Instance Type, vCPU, Memory, Disks) |
| `gather-security-groups.ps1` | `output/security-groups.csv` | Security group rules (SG Name, ID, Type, Protocol, Port, CIDR, Description) |
| `gather-backup-plans.ps1` | `output/backup-plans.csv` | AWS Backup plans (Environment, Backup Name, Schedule, Retention, Region, Copy Region) |

## Usage

Each script will prompt for a **Project tag** value to filter resources. Run each script individually from this directory:

```powershell
# List EC2 instances
.\gather-aws-info.ps1

# Server specifications (CPU, memory, disks)
.\gather-server-specs.ps1

# Security group rules
.\gather-security-groups.ps1

# AWS Backup plans
.\gather-backup-plans.ps1
```

Or run all at once:

```powershell
Get-ChildItem .\gather-*.ps1 | ForEach-Object { & $_.FullName }
```

## Output

All CSV files are created in the `output/` directory. The folder is auto-created if it doesn't exist. Open the CSVs with Excel, Google Sheets, or any CSV viewer.

## Multi-Region

These scripts query the region configured in your AWS CLI profile. To gather data from a different region:

```powershell
$env:AWS_DEFAULT_REGION = "ap-southeast-1"
.\gather-aws-info.ps1
```

Or run across multiple regions:

```powershell
$regions = @("ap-southeast-1", "ap-southeast-3", "us-east-1")
foreach ($region in $regions) {
    $env:AWS_DEFAULT_REGION = $region
    Write-Host "--- Region: $region ---"
    Get-ChildItem .\gather-*.ps1 | ForEach-Object { & $_.FullName }
}
```

## Required IAM Permissions

Minimum IAM policy needed:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeVolumes",
        "ec2:DescribeSecurityGroups",
        "backup:ListBackupPlans",
        "backup:GetBackupPlan",
        "backup:ListTags"
      ],
      "Resource": "*"
    }
  ]
}
```
