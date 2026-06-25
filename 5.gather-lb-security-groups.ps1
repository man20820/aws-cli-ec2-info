# ============================================
# AWS Load Balancer Security Group Rules
# Output: lb-security-groups.csv
# Columns: SGName, SGID, Type, Protocol, Port, CIDR, Description
# User selects load balancers manually from the list
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS LB Security Groups Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Ensure Output Directory ---
$stepStart = Get-Date
Write-Host "[Step 1/6] Checking output directory..." -ForegroundColor Yellow
if (-not (Test-Path ".\output")) {
    New-Item -ItemType Directory -Path ".\output" | Out-Null
    Write-Host "         Created .\output directory" -ForegroundColor Gray
} else {
    Write-Host "         .\output already exists" -ForegroundColor Gray
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 1/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 2: AWS CLI - Describe Load Balancers ---
$stepStart = Get-Date
Write-Host "[Step 2/6] Calling AWS ELBv2 describe-load-balancers..." -ForegroundColor Yellow

$allLBs = aws elbv2 describe-load-balancers `
  --query "LoadBalancers[].{LoadBalancerArn:LoadBalancerArn,LoadBalancerName:LoadBalancerName,Type:Type,SecurityGroups:SecurityGroups}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$lbCount = if ($allLBs) { $allLBs.Count } else { 0 }
Write-Host "[Step 2/6] Done. Retrieved $lbCount load balancers. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allLBs) {
    Write-Host "Error: AWS CLI call failed or no load balancers found." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\lb-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 3: Manual Selection ---
$stepStart = Get-Date
Write-Host "[Step 3/6] Select load balancers to include..." -ForegroundColor Yellow
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
Write-Host "[Step 3/6] Done. Selected $filteredCount load balancers. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Error: No valid load balancers selected." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\lb-security-groups.csv" -NoTypeInformation
    exit 0
}

# Collect unique SG IDs from selected LBs (only ALBs have SGs, NLBs typically don't)
$sgIds = $filteredLBs | ForEach-Object { $_.SecurityGroups } | Where-Object { $_ } | Select-Object -Unique
$sgCount = if ($sgIds) { @($sgIds).Count } else { 0 }

Write-Host "         Collected $sgCount unique security groups from selected LBs." -ForegroundColor Gray

if ($sgCount -eq 0) {
    Write-Host ""
    Write-Host "Warning: Selected load balancers have no security groups (NLBs don't use SGs)." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\lb-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 4: AWS CLI - Describe Security Groups ---
$stepStart = Get-Date
Write-Host "[Step 4/6] Calling AWS EC2 describe-security-groups ($sgCount groups)..." -ForegroundColor Yellow

$sgs = aws ec2 describe-security-groups `
  --group-ids $sgIds `
  --query "SecurityGroups[]" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart

if (-not $sgs) {
    Write-Host "[Step 4/6] ERROR: describe-security-groups failed." -ForegroundColor Red
    Write-Host "         Check permissions: ec2:DescribeSecurityGroups required." -ForegroundColor Gray
    Export-Csv -InputObject @() -Path ".\output\lb-security-groups.csv" -NoTypeInformation
    exit 1
}

Write-Host "[Step 4/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 5: Parse Rules ---
$stepStart = Get-Date
Write-Host "[Step 5/6] Parsing ingress/egress rules..." -ForegroundColor Yellow

$results = @()

foreach ($sg in $sgs) {
    # Ingress rules
    foreach ($rule in $sg.IpPermissions) {
        $protocol = if ($rule.IpProtocol -eq "-1") { "All" } else { $rule.IpProtocol }
        $port = if ($rule.FromPort -eq $rule.ToPort) {
            if ($null -eq $rule.FromPort) { "All" } else { "$($rule.FromPort)" }
        } else {
            "$($rule.FromPort)-$($rule.ToPort)"
        }

        # IPv4 CIDR ranges
        foreach ($cidr in $rule.IpRanges) {
            $results += [PSCustomObject]@{
                SGName      = $sg.GroupName
                SGID        = $sg.GroupId
                Type        = "Ingress"
                Protocol    = $protocol
                Port        = $port
                CIDR        = $cidr.CidrIp
                Description = if ($cidr.Description) { $cidr.Description } else { "N/A" }
            }
        }

        # IPv6 CIDR ranges
        foreach ($cidr in $rule.Ipv6Ranges) {
            $results += [PSCustomObject]@{
                SGName      = $sg.GroupName
                SGID        = $sg.GroupId
                Type        = "Ingress"
                Protocol    = $protocol
                Port        = $port
                CIDR        = $cidr.CidrIpv6
                Description = if ($cidr.Description) { $cidr.Description } else { "N/A" }
            }
        }
    }

    # Egress rules
    foreach ($rule in $sg.IpPermissionsEgress) {
        $protocol = if ($rule.IpProtocol -eq "-1") { "All" } else { $rule.IpProtocol }
        $port = if ($rule.FromPort -eq $rule.ToPort) {
            if ($null -eq $rule.FromPort) { "All" } else { "$($rule.FromPort)" }
        } else {
            "$($rule.FromPort)-$($rule.ToPort)"
        }

        # IPv4 CIDR ranges
        foreach ($cidr in $rule.IpRanges) {
            $results += [PSCustomObject]@{
                SGName      = $sg.GroupName
                SGID        = $sg.GroupId
                Type        = "Egress"
                Protocol    = $protocol
                Port        = $port
                CIDR        = $cidr.CidrIp
                Description = if ($cidr.Description) { $cidr.Description } else { "N/A" }
            }
        }

        # IPv6 CIDR ranges
        foreach ($cidr in $rule.Ipv6Ranges) {
            $results += [PSCustomObject]@{
                SGName      = $sg.GroupName
                SGID        = $sg.GroupId
                Type        = "Egress"
                Protocol    = $protocol
                Port        = $port
                CIDR        = $cidr.CidrIpv6
                Description = if ($cidr.Description) { $cidr.Description } else { "N/A" }
            }
        }
    }
}

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 5/6] Done. Found $($results.Count) rules. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 6: Export ---
$stepStart = Get-Date
Write-Host "[Step 6/6] Exporting to CSV..." -ForegroundColor Yellow

$results | Export-Csv -Path ".\output\lb-security-groups.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 6/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\lb-security-groups.csv ($($results.Count) rules from $sgCount security groups)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
