# ============================================
# AWS Load Balancer Information
# Output: loadbalancers.csv
# Columns: Name, Type (ALB/NLB), DNS, Listeners
# Filtered by Project tag (user input)
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS Load Balancer Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: User Input ---
$stepStart = Get-Date
Write-Host "[Step 1/6] Prompting for Project tag..." -ForegroundColor Yellow
$projectTag = Read-Host "Enter the Project tag value to filter load balancers"
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

# --- Step 4: AWS CLI - Describe Load Balancers ---
$stepStart = Get-Date
Write-Host "[Step 4/6] Calling AWS ELBv2 describe-load-balancers..." -ForegroundColor Yellow

$allLBs = aws elbv2 describe-load-balancers `
  --query "LoadBalancers[].{LoadBalancerArn:LoadBalancerArn,LoadBalancerName:LoadBalancerName,Type:Type,DNSName:DNSName,SecurityGroups:SecurityGroups}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$lbCount = if ($allLBs) { $allLBs.Count } else { 0 }
Write-Host "[Step 4/6] Done. Retrieved $lbCount load balancers. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allLBs) {
    Write-Host "Error: AWS CLI call failed or no load balancers found." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\loadbalancers.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 5: Filter by Project Tag ---
$stepStart = Get-Date
Write-Host "[Step 5/6] Checking tags for each load balancer ($lbCount LBs)..." -ForegroundColor Yellow
Write-Host "         This makes 1 API call per LB to check tags." -ForegroundColor Gray

$filteredLBs = @()
$processedLBs = 0

foreach ($lb in $allLBs) {
    $processedLBs++

    $tags = aws elbv2 describe-tags `
      --resource-arns $lb.LoadBalancerArn `
      --query "TagDescriptions[0].Tags" `
      --output json 2>$null | ConvertFrom-Json

    $projectMatch = $false
    if ($tags) {
        $projTag = $tags | Where-Object { $_.Key -eq "Project" -or $_.Key -eq "project" }
        if ($projTag -and $projTag.Value -eq $projectTag) { $projectMatch = $true }
    }

    if ($projectMatch) {
        $filteredLBs += $lb
        Write-Host "         [$processedLBs/$lbCount] $($lb.LoadBalancerName) - Matched!" -ForegroundColor Green
    } else {
        Write-Host "         [$processedLBs/$lbCount] $($lb.LoadBalancerName) - Skipped." -ForegroundColor DarkGray
    }
}

$elapsed = (Get-Date) - $stepStart
$filteredCount = $filteredLBs.Count
Write-Host "[Step 5/6] Done. Found $filteredCount matching load balancers. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Warning: No load balancers found with Project tag '$projectTag'" -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\loadbalancers.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 6: Get Listeners & Export ---
$stepStart = Get-Date
Write-Host "[Step 6/6] Fetching listeners for $filteredCount load balancers..." -ForegroundColor Yellow

$results = @()
$processedLBs = 0

foreach ($lb in $filteredLBs) {
    $processedLBs++
    Write-Host "         [$processedLBs/$filteredCount] $($lb.LoadBalancerName)..." -ForegroundColor Gray

    $listeners = aws elbv2 describe-listeners `
      --load-balancer-arn $lb.LoadBalancerArn `
      --query "Listeners[].{Protocol:Protocol,Port:Port}" `
      --output json 2>$null | ConvertFrom-Json

    $listenerStr = "N/A"
    if ($listeners) {
        $listenerStr = ($listeners | ForEach-Object { "$($_.Protocol):$($_.Port)" }) -join ", "
    }

    $lbType = switch ($lb.Type) {
        "application" { "ALB" }
        "network"     { "NLB" }
        "gateway"     { "GLB" }
        default       { $lb.Type }
    }

    $results += [PSCustomObject]@{
        Name      = $lb.LoadBalancerName
        Type      = $lbType
        DNS       = $lb.DNSName
        Listeners = $listenerStr
    }
}

$results | Export-Csv -Path ".\output\loadbalancers.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 6/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\loadbalancers.csv ($($results.Count) load balancers)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
