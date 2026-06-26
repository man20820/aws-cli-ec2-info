# ============================================
# AWS Load Balancer Information
# Output: loadbalancers.csv
# Columns: Name, Type (ALB/NLB), DNS, Listeners
# User selects load balancers manually from the list
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS Load Balancer Gathering ===" -ForegroundColor Cyan
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

# --- Step 2: AWS CLI - Describe Load Balancers ---
$stepStart = Get-Date
Write-Host "[Step 2/5] Calling AWS ELBv2 describe-load-balancers..." -ForegroundColor Yellow

$allLBs = aws elbv2 describe-load-balancers `
  --query "LoadBalancers[].{LoadBalancerArn:LoadBalancerArn,LoadBalancerName:LoadBalancerName,Type:Type,DNSName:DNSName,SecurityGroups:SecurityGroups}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$lbCount = if ($allLBs) { $allLBs.Count } else { 0 }
Write-Host "[Step 2/5] Done. Retrieved $lbCount load balancers. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allLBs) {
    Write-Host "Error: AWS CLI call failed or no load balancers found." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\loadbalancers.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 3: Manual Selection ---
$stepStart = Get-Date
Write-Host "[Step 3/5] Select load balancers to include..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Available load balancers:" -ForegroundColor White
for ($i = 0; $i -lt $allLBs.Count; $i++) {
    $lbType = switch ($allLBs[$i].Type) {
        "application" { "ALB" }
        "network"     { "NLB" }
        "gateway"     { "GLB" }
        default       { $allLBs[$i].Type }
    }
    Write-Host "    [$($i + 1)] $($allLBs[$i].LoadBalancerName) ($lbType)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Enter numbers separated by comma (e.g. 1,3,5) or 'all' for all:" -ForegroundColor Gray
$selection = Read-Host "  Selection"

if ($selection -eq "all" -or [string]::IsNullOrWhiteSpace($selection)) {
    $filteredLBs = $allLBs
    Write-Host "         Selected all $lbCount load balancers." -ForegroundColor Green
} else {
    $indices = $selection -split "," | ForEach-Object { $_.Trim() }
    $filteredLBs = @()
    foreach ($idx in $indices) {
        $num = 0
        if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $lbCount) {
            $filteredLBs += $allLBs[$num - 1]
        } else {
            Write-Host "         Warning: Invalid selection '$idx' - skipped." -ForegroundColor Yellow
        }
    }
}

$filteredCount = if ($filteredLBs) { @($filteredLBs).Count } else { 0 }
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 3/5] Done. Selected $filteredCount load balancers. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Error: No valid load balancers selected." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\loadbalancers.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 4: Get Listeners ---
$stepStart = Get-Date
Write-Host "[Step 4/5] Fetching listeners for $filteredCount load balancers..." -ForegroundColor Yellow

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

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 4/5] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 5: Export ---
$stepStart = Get-Date
Write-Host "[Step 5/5] Exporting to CSV..." -ForegroundColor Yellow

$results | Export-Csv -Path ".\output\loadbalancers.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 5/5] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\loadbalancers.csv ($($results.Count) load balancers)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
