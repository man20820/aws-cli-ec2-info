# ============================================
# AWS Infrastructure Information Gathering
# Output: CSV files for customer handover
# ============================================

# --- EC2 Instances ---
# Columns: No, Name, IP Address, Instance Detail, Environment
# Filtered by Project tag (user input)

$scriptStart = Get-Date
Write-Host "=== AWS EC2 Info Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: User Input ---
$stepStart = Get-Date
Write-Host "[Step 1/6] Prompting for Project tag..." -ForegroundColor Yellow
$projectTag = Read-Host "Enter the Project tag value to filter EC2 instances"
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

# --- Step 4: AWS CLI Call ---
$stepStart = Get-Date
Write-Host "[Step 4/6] Calling AWS EC2 describe-instances..." -ForegroundColor Yellow
Write-Host "         This may take a while depending on the number of instances." -ForegroundColor Gray

$allInstances = aws ec2 describe-instances `
  --query "Reservations[].Instances[?State.Name!='terminated'][].{Name:Tags[?Key=='Name']|[0].Value,PrivateIP:PrivateIpAddress,InstanceType:InstanceType,Environment:Tags[?Key=='Environment']|[0].Value,Project:Tags[?Key=='Project']|[0].Value}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$instanceCount = if ($allInstances) { $allInstances.Count } else { 0 }
Write-Host "[Step 4/6] Done. Retrieved $instanceCount total instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allInstances) {
    Write-Host "Error: AWS CLI call failed or no instances found." -ForegroundColor Red
    Write-Host "         Check your AWS credentials and network connectivity." -ForegroundColor Gray
    exit 1
}
Write-Host ""

# --- Step 5: Filter by Project Tag ---
$stepStart = Get-Date
Write-Host "[Step 5/6] Filtering instances by Project tag '$projectTag'..." -ForegroundColor Yellow

$filtered = $allInstances | Where-Object { $_.Project -eq $projectTag }

$elapsed = (Get-Date) - $stepStart
$filteredCount = if ($filtered) { @($filtered).Count } else { 0 }
Write-Host "[Step 5/6] Done. Found $filteredCount matching instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host "" 
    Write-Host "Warning: No instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    Write-Host "Checking available Project tag values..." -ForegroundColor Gray
    $allProjects = $allInstances | Select-Object -ExpandProperty Project -Unique | Where-Object { $_ }
    if ($allProjects) {
        Write-Host "Available Project tags: $($allProjects -join ', ')" -ForegroundColor Cyan
    } else {
        Write-Host "No instances have a 'Project' tag. Check if your tag key is exactly 'Project' (case-sensitive)." -ForegroundColor Red
    }
    Export-Csv -InputObject @() -Path ".\output\ec2-instances.csv" -NoTypeInformation
    Write-Host ""
    Write-Host "Output: output\ec2-instances.csv (0 rows)" -ForegroundColor Cyan
    exit 0
}
Write-Host ""

# --- Step 6: Export to CSV ---
$stepStart = Get-Date
Write-Host "[Step 6/6] Exporting to CSV..." -ForegroundColor Yellow

$rowNum = 0
$results = $filtered | Select-Object `
  @{Name='No';Expression={ $script:rowNum++; $script:rowNum }},
  @{Name='Name';Expression={ $_.Name }},
  @{Name='IP Address';Expression={ $_.PrivateIP }},
  @{Name='Instance Detail';Expression={ $_.InstanceType }},
  @{Name='Environment';Expression={ $_.Environment }}

$results | Export-Csv -Path ".\output\ec2-instances.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 6/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\ec2-instances.csv ($filteredCount rows)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
