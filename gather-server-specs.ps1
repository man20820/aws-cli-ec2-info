# ============================================
# AWS Server Specifications
# Output: ec2-server-specs.csv
# Columns: Name, Platform, Instance Type, vCPU, Memory (GB), Disks
# Filtered by Project tag (user input)
# ============================================

$projectTag = Read-Host "Enter the Project tag value to filter EC2 instances"

if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host "Gathering server specifications for Project: $projectTag ..."

# Ensure output directory exists
if (-not (Test-Path ".\output")) { New-Item -ItemType Directory -Path ".\output" | Out-Null }

# Get all instances with Project tag
$allInstances = aws ec2 describe-instances `
  --query "Reservations[].Instances[?State.Name!='terminated'].{InstanceId:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Platform:Platform,InstanceType:InstanceType,Project:Tags[?Key=='Project']|[0].Value}" `
  --output json | ConvertFrom-Json

if (-not $allInstances) {
    Write-Host "Error: AWS CLI call failed or no instances found." -ForegroundColor Red
    exit 1
}

$instances = $allInstances | Where-Object { $_.Project -eq $projectTag }

if ($instances.Count -eq 0) {
    Write-Host "Warning: No instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    $allProjects = $allInstances | Select-Object -ExpandProperty Project -Unique | Where-Object { $_ }
    if ($allProjects) {
        Write-Host "Available Project tags: $($allProjects -join ', ')"
    }
    Export-Csv -InputObject @() -Path ".\output\ec2-server-specs.csv" -NoTypeInformation
    exit 0
}

# Get unique instance types and look up specs
$instanceTypes = $instances | Select-Object -ExpandProperty InstanceType -Unique
$specs = aws ec2 describe-instance-types `
  --instance-types $instanceTypes `
  --query "InstanceTypes[].{InstanceType:InstanceType,VCpus:VCpuInfo.DefaultVCpus,MemoryMB:MemoryInfo.SizeInMiB}" `
  --output json | ConvertFrom-Json

# Build a lookup hashtable for specs
$specsLookup = @{}
foreach ($s in $specs) {
    $specsLookup[$s.InstanceType] = @{
        VCpus = $s.VCpus
        MemoryGB = [math]::Round($s.MemoryMB / 1024, 1)
    }
}

# Get all volumes and map to instances
$volumes = aws ec2 describe-volumes `
  --query "Volumes[].{VolumeId:VolumeId,Size:Size,Device:Attachments[0].Device,InstanceId:Attachments[0].InstanceId}" `
  --output json | ConvertFrom-Json

# Build disk lookup by instance ID
$diskLookup = @{}
foreach ($v in $volumes) {
    if ($v.InstanceId) {
        if (-not $diskLookup.ContainsKey($v.InstanceId)) {
            $diskLookup[$v.InstanceId] = @()
        }
        $diskLookup[$v.InstanceId] += "$($v.Device) $($v.Size)GB"
    }
}

# Build results
$results = foreach ($inst in $instances) {
    $specInfo = $specsLookup[$inst.InstanceType]
    $disks = if ($diskLookup.ContainsKey($inst.InstanceId)) {
        ($diskLookup[$inst.InstanceId]) -join ", "
    } else { "N/A" }

    [PSCustomObject]@{
        Name         = if ($inst.Name) { $inst.Name } else { "N/A" }
        Platform     = if ($inst.Platform) { $inst.Platform } else { "Linux/UNIX" }
        InstanceType = $inst.InstanceType
        VCpus        = $specInfo.VCpus
        MemoryGB     = $specInfo.MemoryGB
        Disks        = $disks
    }
}

$results | Export-Csv -Path ".\output\ec2-server-specs.csv" -NoTypeInformation

Write-Host "Done! Output: output\ec2-server-specs.csv"
