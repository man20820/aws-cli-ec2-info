# ============================================
# AWS Backup Plans
# Output: backup-plans.csv
# Columns: BackupName, RuleName, Schedule, Retention (Days), Region, Copy Region
# User selects backup plans manually from the list
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS Backup Plans Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Ensure Output Directory ---
$stepStart = Get-Date
Write-Host "[Step 1/5] Checking output directory..." -ForegroundColor Yellow
if (-not (Test-Path ".\output")) {
    New-Item -ItemType Directory -Path ".\output" | Out-Null
    Write-Host "         Created .\output directory" -ForegroundColor Gray
} else {
    Write-Host "         .\output already exists" -ForegroundColor Gray
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 1/5] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 2: AWS CLI - List Backup Plans ---
$stepStart = Get-Date
Write-Host "[Step 2/5] Calling AWS Backup list-backup-plans..." -ForegroundColor Yellow

$allPlans = aws backup list-backup-plans `
  --query "BackupPlansList[].{BackupPlanId:BackupPlanId,BackupPlanName:BackupPlanName}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$planCount = if ($allPlans) { $allPlans.Count } else { 0 }
Write-Host "[Step 2/5] Done. Found $planCount backup plans. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allPlans) {
    Write-Host "Warning: No backup plans found or AWS CLI call failed." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\backup-plans.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 3: Manual Selection ---
$stepStart = Get-Date
Write-Host "[Step 3/5] Select backup plans to include..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Available backup plans:" -ForegroundColor White
for ($i = 0; $i -lt $allPlans.Count; $i++) {
    Write-Host "    [$($i + 1)] $($allPlans[$i].BackupPlanName)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Enter numbers separated by comma (e.g. 1,3,5) or 'all' for all:" -ForegroundColor Gray
$selection = Read-Host "  Selection"

if ($selection -eq "all" -or [string]::IsNullOrWhiteSpace($selection)) {
    $filteredPlans = $allPlans
    Write-Host "         Selected all $planCount plans." -ForegroundColor Green
} else {
    $indices = $selection -split "," | ForEach-Object { $_.Trim() }
    $filteredPlans = @()
    foreach ($idx in $indices) {
        $num = 0
        if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $planCount) {
            $filteredPlans += $allPlans[$num - 1]
        } else {
            Write-Host "         Warning: Invalid selection '$idx' - skipped." -ForegroundColor Yellow
        }
    }
}

$filteredCount = if ($filteredPlans) { @($filteredPlans).Count } else { 0 }
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 3/5] Done. Selected $filteredCount backup plans. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Error: No valid plans selected." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\backup-plans.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 4: Get Region & Plan Details ---
$stepStart = Get-Date
Write-Host "[Step 4/5] Getting region and fetching plan details ($filteredCount plans)..." -ForegroundColor Yellow

$region = (aws configure get region)
if ([string]::IsNullOrWhiteSpace($region)) { $region = $env:AWS_DEFAULT_REGION }
if ([string]::IsNullOrWhiteSpace($region)) { $region = $env:AWS_REGION }
if ([string]::IsNullOrWhiteSpace($region)) {
    $region = "UNKNOWN"
    Write-Host "         WARNING: Could not determine AWS region." -ForegroundColor Red
} else {
    Write-Host "         Region: $region" -ForegroundColor Gray
}

$results = @()
$processedPlans = 0

foreach ($plan in $filteredPlans) {
    $processedPlans++
    Write-Host "         [$processedPlans/$filteredCount] Processing: $($plan.BackupPlanName)..." -ForegroundColor Gray

    $planDetail = aws backup get-backup-plan `
      --backup-plan-id $plan.BackupPlanId `
      --output json | ConvertFrom-Json

    if (-not $planDetail) {
        Write-Host "         [$processedPlans/$filteredCount] WARNING: Failed to get plan details. Skipping." -ForegroundColor Red
        continue
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
Write-Host "[Step 4/5] Done. Collected $($results.Count) rules. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 5: Export ---
$stepStart = Get-Date
Write-Host "[Step 5/5] Exporting to CSV..." -ForegroundColor Yellow

$results | Export-Csv -Path ".\output\backup-plans.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 5/5] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\backup-plans.csv ($($results.Count) rules from $filteredCount plans)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
