# ============================================
# AWS Security Group Rules
# Output: security-groups.csv
# Columns: SG Name, SG ID, Type, Protocol, Port, CIDR, Description
# Filtered by Project tag (only SGs attached to instances with matching Project tag)
# ============================================

$projectTag = Read-Host "Enter the Project tag value to filter security groups"

if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host "Gathering security group rules for Project: $projectTag ..."

# Ensure output directory exists
if (-not (Test-Path ".\output")) { New-Item -ItemType Directory -Path ".\output" | Out-Null }

# Get instances with Project tag to find their security groups
$allInstances = aws ec2 describe-instances `
  --query "Reservations[].Instances[?State.Name!='terminated'].{SecurityGroups:SecurityGroups[].GroupId,Project:Tags[?Key=='Project']|[0].Value}" `
  --output json | ConvertFrom-Json

if (-not $allInstances) {
    Write-Host "Error: AWS CLI call failed or no instances found." -ForegroundColor Red
    exit 1
}

$filteredInstances = $allInstances | Where-Object { $_.Project -eq $projectTag }

if ($filteredInstances.Count -eq 0) {
    Write-Host "Warning: No instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    $allProjects = $allInstances | Select-Object -ExpandProperty Project -Unique | Where-Object { $_ }
    if ($allProjects) {
        Write-Host "Available Project tags: $($allProjects -join ', ')"
    }
    Export-Csv -InputObject @() -Path ".\output\security-groups.csv" -NoTypeInformation
    exit 0
}

# Collect unique SG IDs from matching instances
$sgIds = $filteredInstances | ForEach-Object { $_.SecurityGroups } | Select-Object -Unique

# Get security groups by IDs
$sgs = aws ec2 describe-security-groups `
  --group-ids $sgIds `
  --query "SecurityGroups[]" `
  --output json | ConvertFrom-Json

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

Write-Host "Done! Output: output\security-groups.csv"
Write-Host "Total rules: $($results.Count)"
