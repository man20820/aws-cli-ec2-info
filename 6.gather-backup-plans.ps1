# ============================================
# AWS Backup Plans
# Output: backup-plans.csv
# Columns: Environment, Backup Name, Schedule, Retention (Days), Region, Copy Region
# Filtered by Project tag (user input)
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS Backup Plans Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: User Input ---
$stepStart = Get-Date
Write-Host "[Step 1/6] Prompting for Project tag..." -ForegroundColor Yellow
$projectTag = Read-Host "Enter the Project tag value to filter backup plans"
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 1/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 2: Validate Input ---
$stepStart = Get-Date
Write-Host "[Step 2/6] Validating input..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 2/6] Input OK: '$projectTag' (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 3: Ensure Output Directory ---
$stepStart = Get-Date
Write-Host "[Step 3/6] Checking output directory..." -ForegroundColor Yellow
if (-not (Test-Path ".\output")) {
    New-Item -ItemType Directory -Path ".\output" | Out-Null
    Write-Host "         Created .\output directory" -ForegroundColor Gray
} else {
    Write-Host "         .\output already exists" -ForegroundColor Gray
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 3/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 4: AWS CLI - List Backup Plans ---
$stepStart = Get-Date
Write-Host "[Step 4/6] Calling AWS Backup list-backup-plans..." -ForegroundColor Yellow

$plans = aws backup list-backup-plans `
  --query "BackupPlansList[].{BackupPlanId:BackupPlanId,BackupPlanName:BackupPlanName}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$planCount = if ($plans) { $plans.Count } else { 0 }
Write-Host "[Step 4/6] Done. Found $planCount backup plans. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $plans) {
    Write-Host "Warning: No backup plans found or AWS CLI call failed." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\backup-plans.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 5: Get Region ---
$stepStart = Get-Date
Write-Host "[Step 5/6] Getting current AWS region..." -ForegroundColor Yellow
$region = (aws configure get region)
if ([string]::IsNullOrWhiteSpace($region)) {
    $region = $env:AWS_DEFAULT_REGION
}
if ([string]::IsNullOrWhiteSpace($region)) {
    $region = $env:AWS_REGION
}
if ([string]::IsNullOrWhiteSpace($region)) {
    $region = "UNKNOWN"
    Write-Host "[Step 5/6] WARNING: Could not determine AWS region. Check aws configure or AWS_REGION env var." -ForegroundColor Red
} else {
    Write-Host "[Step 5/6] Region: $region" -ForegroundColor Green
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 5/6] (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 6: Iterate Plans, Check Tags & Export ---
$stepStart = Get-Date
Write-Host "[Step 6/6] Processing each backup plan (get details + check tags)..." -ForegroundColor Yellow
Write-Host "         This step makes 2 API calls per plan ($planCount plans = $($planCount * 2) calls)." -ForegroundColor Gray
Write-Host "         This is likely the slowest step." -ForegroundColor Gray

$results = @()
$matchedPlans = 0
$processedPlans = 0

foreach ($plan in $plans) {
    $processedPlans++
    Write-Host "         [$processedPlans/$planCount] Processing: $($plan.BackupPlanName)..." -ForegroundColor Gray

    # Get plan details (rules contain schedule, retention, copy actions)
    $planDetail = aws backup get-backup-plan `
      --backup-plan-id $plan.BackupPlanId `
      --output json | ConvertFrom-Json

    if (-not $planDetail) {
        Write-Host "         [$processedPlans/$planCount] WARNING: Failed to get plan details. Skipping." -ForegroundColor Red
        continue
    }

    # Get tags for the backup plan
    $planArn = $planDetail.BackupPlanArn
    if (-not $planArn) {
        Write-Host "         [$processedPlans/$planCount] WARNING: No ARN returned. Skipping." -ForegroundColor Red
        continue
    }

    $tags = aws backup list-tags `
      --resource-arn $planArn `
      --output json 2>$null | ConvertFrom-Json

    # Check Project tag - skip if doesn't match
    $projectMatch = $false
    if ($tags.Tags) {
        $projTag = $tags.Tags.PSObject.Properties | Where-Object { $_.Name -eq "Project" -or $_.Name -eq "project" }
        if ($projTag -and $projTag.Value -eq $projectTag) { $projectMatch = $true }
    }
    if (-not $projectMatch) {
        Write-Host "         [$processedPlans/$planCount] Skipped (Project tag mismatch)." -ForegroundColor DarkGray
        continue
    }

    $matchedPlans++
    Write-Host "         [$processedPlans/$planCount] Matched!" -ForegroundColor Green

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

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 6/6] Done. Matched $matchedPlans plans, $($results.Count) rules total. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

$results | Export-Csv -Path ".\output\backup-plans.csv" -NoTypeInformation

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\backup-plans.csv ($($results.Count) rules from $matchedPlans plans)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
