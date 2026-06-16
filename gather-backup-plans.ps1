# ============================================
# AWS Backup Plans
# Output: backup-plans.csv
# Columns: Environment, Backup Name, Schedule, Retention (Days), Region, Copy Region
# Filtered by Project tag (user input)
# ============================================

$projectTag = Read-Host "Enter the Project tag value to filter backup plans"

if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host "Gathering AWS Backup plans for Project: $projectTag ..."

# Ensure output directory exists
if (-not (Test-Path ".\output")) { New-Item -ItemType Directory -Path ".\output" | Out-Null }

# Get all backup plans
$plans = aws backup list-backup-plans `
  --query "BackupPlansList[].{BackupPlanId:BackupPlanId,BackupPlanName:BackupPlanName}" `
  --output json | ConvertFrom-Json

if (-not $plans) {
    Write-Host "Warning: No backup plans found or AWS CLI call failed." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\backup-plans.csv" -NoTypeInformation
    exit 0
}

$region = (aws configure get region)
$results = @()

foreach ($plan in $plans) {
    # Get plan details (rules contain schedule, retention, copy actions)
    $planDetail = aws backup get-backup-plan `
      --backup-plan-id $plan.BackupPlanId `
      --output json | ConvertFrom-Json

    # Get tags for the backup plan
    $planArn = $planDetail.BackupPlanArn
    $tags = aws backup list-tags `
      --resource-arn $planArn `
      --output json 2>$null | ConvertFrom-Json

    # Check Project tag - skip if doesn't match
    $projectMatch = $false
    if ($tags.Tags) {
        $projTag = $tags.Tags.PSObject.Properties | Where-Object { $_.Name -eq "Project" -or $_.Name -eq "project" }
        if ($projTag -and $projTag.Value -eq $projectTag) { $projectMatch = $true }
    }
    if (-not $projectMatch) { continue }

    $environment = "N/A"
    if ($tags.Tags) {
        $envTag = $tags.Tags.PSObject.Properties | Where-Object { $_.Name -eq "Environment" -or $_.Name -eq "environment" -or $_.Name -eq "Env" -or $_.Name -eq "env" }
        if ($envTag) { $environment = $envTag.Value }
    }

    # Each plan can have multiple rules
    foreach ($rule in $planDetail.BackupPlan.Rules) {
        $schedule = if ($rule.ScheduleExpression) { $rule.ScheduleExpression } else { "N/A" }
        $retention = if ($rule.Lifecycle.DeleteAfterDays) { "$($rule.Lifecycle.DeleteAfterDays)" } else { "N/A" }

        # Check for copy actions (cross-region copy)
        $copyRegion = "N/A"
        if ($rule.CopyActions -and $rule.CopyActions.Count -gt 0) {
            $copyRegions = @()
            foreach ($copy in $rule.CopyActions) {
                # Extract region from destination vault ARN
                # Format: arn:aws:backup:<region>:<account>:backup-vault:<name>
                if ($copy.DestinationBackupVaultArn -match "arn:aws:backup:([^:]+):") {
                    $copyRegions += $Matches[1]
                }
            }
            if ($copyRegions.Count -gt 0) {
                $copyRegion = $copyRegions -join ", "
            }
        }

        $results += [PSCustomObject]@{
            Environment   = $environment
            BackupName    = $plan.BackupPlanName
            RuleName      = $rule.RuleName
            Schedule      = $schedule
            RetentionDays = $retention
            Region        = $region
            CopyRegion    = $copyRegion
        }
    }
}

$results | Export-Csv -Path ".\output\backup-plans.csv" -NoTypeInformation

Write-Host "Done! Output: output\backup-plans.csv"
Write-Host "Total rules: $($results.Count)"
