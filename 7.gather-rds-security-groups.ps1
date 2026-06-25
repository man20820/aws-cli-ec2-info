# ============================================
# AWS RDS Security Group Rules
# Output: rds-security-groups.csv
# Columns: SGName, SGID, Type, Protocol, Port, CIDR, Description
# Filtered by Project tag (only SGs attached to RDS instances with matching Project tag)
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS RDS Security Groups Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: User Input ---
$stepStart = Get-Date
Write-Host "[Step 1/7] Prompting for Project tag..." -ForegroundColor Yellow
$projectTag = Read-Host "Enter the Project tag value to filter RDS security groups"
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 1/7] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 2: Validate Input ---
$stepStart = Get-Date
Write-Host "[Step 2/7] Validating input..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 2/7] Input OK: '$projectTag' (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 3: Ensure Output Directory ---
$stepStart = Get-Date
Write-Host "[Step 3/7] Checking output directory..." -ForegroundColor Yellow
if (-not (Test-Path ".\output")) {
    New-Item -ItemType Directory -Path ".\output" | Out-Null
    Write-Host "         Created .\output directory" -ForegroundColor Gray
} else {
    Write-Host "         .\output already exists" -ForegroundColor Gray
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 3/7] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 4: AWS CLI - Describe RDS Instances ---
$stepStart = Get-Date
Write-Host "[Step 4/7] Calling AWS RDS describe-db-instances..." -ForegroundColor Yellow

$allDBInstances = aws rds describe-db-instances `
  --query "DBInstances[].{DBInstanceIdentifier:DBInstanceIdentifier,DBInstanceArn:DBInstanceArn,VpcSecurityGroups:VpcSecurityGroups[].VpcSecurityGroupId}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$dbCount = if ($allDBInstances) { $allDBInstances.Count } else { 0 }
Write-Host "[Step 4/7] Done. Retrieved $dbCount RDS instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allDBInstances) {
    Write-Host "Error: AWS CLI call failed or no RDS instances found." -ForegroundColor Red
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 5: Filter by Project Tag & Collect SG IDs ---
$stepStart = Get-Date
Write-Host "[Step 5/7] Checking tags for each RDS instance ($dbCount instances)..." -ForegroundColor Yellow
Write-Host "         This makes 1 API call per RDS instance to check tags." -ForegroundColor Gray

$filteredDBs = @()
$processedDBs = 0

foreach ($db in $allDBInstances) {
    $processedDBs++

    $tags = aws rds list-tags-for-resource `
      --resource-name $db.DBInstanceArn `
      --query "TagList" `
      --output json 2>$null | ConvertFrom-Json

    $projectMatch = $false
    if ($tags) {
        $projTag = $tags | Where-Object { $_.Key -eq "Project" -or $_.Key -eq "project" }
        if ($projTag -and $projTag.Value -eq $projectTag) { $projectMatch = $true }
    }

    if ($projectMatch) {
        $filteredDBs += $db
        Write-Host "         [$processedDBs/$dbCount] $($db.DBInstanceIdentifier) - Matched!" -ForegroundColor Green
    } else {
        Write-Host "         [$processedDBs/$dbCount] $($db.DBInstanceIdentifier) - Skipped." -ForegroundColor DarkGray
    }
}

$elapsed = (Get-Date) - $stepStart
$filteredCount = $filteredDBs.Count
Write-Host "[Step 5/7] Done. Found $filteredCount matching RDS instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Warning: No RDS instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 0
}

# Collect unique SG IDs from matching RDS instances
$sgIds = $filteredDBs | ForEach-Object { $_.VpcSecurityGroups } | Where-Object { $_ } | Select-Object -Unique
$sgCount = if ($sgIds) { @($sgIds).Count } else { 0 }

Write-Host "         Collected $sgCount unique security groups from matched RDS instances." -ForegroundColor Gray

if ($sgCount -eq 0) {
    Write-Host ""
    Write-Host "Warning: Matched RDS instances have no VPC security groups attached." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 6: AWS CLI - Describe Security Groups ---
$stepStart = Get-Date
Write-Host "[Step 6/7] Calling AWS EC2 describe-security-groups ($sgCount groups)..." -ForegroundColor Yellow

$sgs = aws ec2 describe-security-groups `
  --group-ids $sgIds `
  --query "SecurityGroups[]" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart

if (-not $sgs) {
    Write-Host "[Step 6/7] ERROR: describe-security-groups failed." -ForegroundColor Red
    Write-Host "         Check permissions: ec2:DescribeSecurityGroups required." -ForegroundColor Gray
    Export-Csv -InputObject @() -Path ".\output\rds-security-groups.csv" -NoTypeInformation
    exit 1
}

Write-Host "[Step 6/7] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 7: Parse Rules & Export ---
$stepStart = Get-Date
Write-Host "[Step 7/7] Parsing ingress/egress rules and exporting to CSV..." -ForegroundColor Yellow

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
Write-Host "[Step 7/7] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\rds-security-groups.csv ($($results.Count) rules from $sgCount security groups)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
