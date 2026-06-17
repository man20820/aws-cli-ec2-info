# ============================================
# AWS Security Group Rules
# Output: security-groups.csv
# Columns: SG Name, SG ID, Type, Protocol, Port, CIDR, Description
# Filtered by Project tag (only SGs attached to instances with matching Project tag)
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS Security Groups Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: User Input ---
$stepStart = Get-Date
Write-Host "[Step 1/7] Prompting for Project tag..." -ForegroundColor Yellow
$projectTag = Read-Host "Enter the Project tag value to filter security groups"
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

# --- Step 4: AWS CLI - Describe Instances ---
$stepStart = Get-Date
Write-Host "[Step 4/7] Calling AWS EC2 describe-instances..." -ForegroundColor Yellow
Write-Host "         Fetching security group associations for all instances." -ForegroundColor Gray

$allInstances = aws ec2 describe-instances `
  --query "Reservations[].Instances[?State.Name!='terminated'][].{SecurityGroups:SecurityGroups[].GroupId,Project:Tags[?Key=='Project']|[0].Value}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$instanceCount = if ($allInstances) { $allInstances.Count } else { 0 }
Write-Host "[Step 4/7] Done. Retrieved $instanceCount instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allInstances) {
    Write-Host "Error: AWS CLI call failed or no instances found." -ForegroundColor Red
    exit 1
}
Write-Host ""

# --- Step 5: Filter Instances & Collect SG IDs ---
$stepStart = Get-Date
Write-Host "[Step 5/7] Filtering instances by Project tag '$projectTag'..." -ForegroundColor Yellow

$filteredInstances = $allInstances | Where-Object { $_.Project -eq $projectTag }

$filteredCount = if ($filteredInstances) { @($filteredInstances).Count } else { 0 }

if ($filteredCount -eq 0) {
    Write-Host "Warning: No instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    $allProjects = $allInstances | Select-Object -ExpandProperty Project -Unique | Where-Object { $_ }
    if ($allProjects) {
        Write-Host "Available Project tags: $($allProjects -join ', ')" -ForegroundColor Cyan
    }
    Export-Csv -InputObject @() -Path ".\output\security-groups.csv" -NoTypeInformation
    exit 0
}

# Collect unique SG IDs from matching instances
$sgIds = $filteredInstances | ForEach-Object { $_.SecurityGroups } | Where-Object { $_ } | Select-Object -Unique
$sgCount = if ($sgIds) { @($sgIds).Count } else { 0 }

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 5/7] Done. Found $filteredCount instances, $sgCount unique security groups. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($sgCount -eq 0) {
    Write-Host "Warning: Matching instances have no security groups attached." -ForegroundColor Yellow
    Export-Csv -InputObject @() -Path ".\output\security-groups.csv" -NoTypeInformation
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
    Export-Csv -InputObject @() -Path ".\output\security-groups.csv" -NoTypeInformation
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

$results | Export-Csv -Path ".\output\security-groups.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 7/7] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\security-groups.csv ($($results.Count) rules)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
