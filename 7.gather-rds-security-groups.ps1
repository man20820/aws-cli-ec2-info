# ============================================
# AWS RDS Security Group Rules
# Output: rds-security-groups.csv
# Columns: SGName, SGID, Type, Protocol, Port, CIDR, Description
# User selects RDS instances manually from the list
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS RDS Security Groups Gathering ===" -ForegroundColor Cyan
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

# --- Step 2: AWS CLI - Describe RDS Instances ---
$stepStart = Get-Date
Write-Host "[Step 2/6] Calling AWS RDS describe-db-instances..." -ForegroundColor Yellow

$allDBInstances = aws rds describe-db-instances `
  --query "DBInstances[].{DBInstanceIdentifier:DBInstanceIdentifier,VpcSecurityGroups:VpcSecurityGroups[].VpcSecurityGroupId}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$dbCount = if ($allDBInstances) { $allDBInstances.Count } else { 0 }
Write-Host "[Step 2/6] Done. Retrieved $dbCount RDS instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allDBInstances) {
    Write-Host "Error: AWS CLI call failed or no RDS instances found." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 3: Manual Selection ---
$stepStart = Get-Date
Write-Host "[Step 3/6] Select RDS instances to include..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Available RDS instances:" -ForegroundColor White
for ($i = 0; $i -lt $allDBInstances.Count; $i++) {
    Write-Host "    [$($i + 1)] $($allDBInstances[$i].DBInstanceIdentifier)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Enter numbers separated by comma (e.g. 1,3,5) or 'all' for all:" -ForegroundColor Gray
$selection = Read-Host "  Selection"

if ($selection -eq "all" -or [string]::IsNullOrWhiteSpace($selection)) {
    $filteredDBs = $allDBInstances
    Write-Host "         Selected all $dbCount instances." -ForegroundColor Green
} else {
    $indices = $selection -split "," | ForEach-Object { $_.Trim() }
    $filteredDBs = @()
    foreach ($idx in $indices) {
        $num = 0
        if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $dbCount) {
            $filteredDBs += $allDBInstances[$num - 1]
        } else {
            Write-Host "         Warning: Invalid selection '$idx' - skipped." -ForegroundColor Yellow
        }
    }
}

$filteredCount = if ($filteredDBs) { @($filteredDBs).Count } else { 0 }
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 3/6] Done. Selected $filteredCount RDS instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Error: No valid instances selected." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 4: Collect Security Group IDs ---
$stepStart = Get-Date
Write-Host "[Step 4/6] Collecting security group IDs from selected instances..." -ForegroundColor Yellow

$sgIds = $filteredDBs | ForEach-Object { $_.VpcSecurityGroups } | Where-Object { $_ } | Select-Object -Unique
$sgCount = if ($sgIds) { @($sgIds).Count } else { 0 }

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 4/6] Done. Found $sgCount unique security groups. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($sgCount -eq 0) {
    Write-Host ""
    Write-Host "Warning: Selected RDS instances have no VPC security groups attached." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 5: AWS CLI - Describe Security Groups ---
$stepStart = Get-Date
Write-Host "[Step 5/6] Calling AWS EC2 describe-security-groups ($sgCount groups)..." -ForegroundColor Yellow

$sgs = aws ec2 describe-security-groups `
  --group-ids $sgIds `
  --query "SecurityGroups[]" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart

if (-not $sgs) {
    Write-Host "[Step 5/6] ERROR: describe-security-groups failed." -ForegroundColor Red
    Write-Host "         Check permissions: ec2:DescribeSecurityGroups required." -ForegroundColor Gray
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 1
}

Write-Host "[Step 5/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 6: Parse Rules & Export ---
$stepStart = Get-Date
Write-Host "[Step 6/6] Parsing ingress/egress rules and exporting to CSV..." -ForegroundColor Yellow

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

$results | Export-Csv -Path ".\output\rds-security-groups.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 6/6] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\rds-security-groups.csv ($($results.Count) rules from $sgCount security groups)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
