# ============================================
# AWS Server Specifications
# Output: ec2-server-specs.csv
# Columns: Name, Platform, Instance Type, vCPU, Memory (GB), Disks
# Filtered by Project tag (user input)
# ============================================

$scriptStart = Get-Date
Write-Host "=== AWS Server Specs Gathering ===" -ForegroundColor Cyan
Write-Host "Started at: $($scriptStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: User Input ---
$stepStart = Get-Date
Write-Host "[Step 1/8] Prompting for Project tag..." -ForegroundColor Yellow
$projectTag = Read-Host "Enter the Project tag value to filter EC2 instances"
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 1/8] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 2: Validate Input ---
$stepStart = Get-Date
Write-Host "[Step 2/8] Validating input..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 2/8] Input OK: '$projectTag' (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 3: Ensure Output Directory ---
$stepStart = Get-Date
Write-Host "[Step 3/8] Checking output directory..." -ForegroundColor Yellow
if (-not (Test-Path ".\output")) {
    New-Item -ItemType Directory -Path ".\output" | Out-Null
    Write-Host "         Created .\output directory" -ForegroundColor Gray
} else {
    Write-Host "         .\output already exists" -ForegroundColor Gray
}
$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 3/8] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Step 4: AWS CLI - Describe Instances ---
$stepStart = Get-Date
Write-Host "[Step 4/8] Calling AWS EC2 describe-instances..." -ForegroundColor Yellow
Write-Host "         Fetching instance metadata (ID, Name, Platform, Type, Project)." -ForegroundColor Gray

$allInstances = aws ec2 describe-instances `
  --query "Reservations[].Instances[?State.Name!='terminated'][].{InstanceId:InstanceId,Name:Tags[?Key=='Name']|[0].Value,Platform:Platform,InstanceType:InstanceType,Project:Tags[?Key=='Project']|[0].Value}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$instanceCount = if ($allInstances) { $allInstances.Count } else { 0 }
Write-Host "[Step 4/8] Done. Retrieved $instanceCount total instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if (-not $allInstances) {
    Write-Host "Error: AWS CLI call failed or no instances found." -ForegroundColor Red
    exit 1
}
Write-Host ""

# --- Step 5: Filter by Project Tag ---
$stepStart = Get-Date
Write-Host "[Step 5/8] Filtering instances by Project tag '$projectTag'..." -ForegroundColor Yellow

$instances = $allInstances | Where-Object { $_.Project -eq $projectTag }

$elapsed = (Get-Date) - $stepStart
$filteredCount = if ($instances) { @($instances).Count } else { 0 }
Write-Host "[Step 5/8] Done. Found $filteredCount matching instances. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green

if ($filteredCount -eq 0) {
    Write-Host ""
    Write-Host "Warning: No instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    $allProjects = $allInstances | Select-Object -ExpandProperty Project -Unique | Where-Object { $_ }
    if ($allProjects) {
        Write-Host "Available Project tags: $($allProjects -join ', ')" -ForegroundColor Cyan
    }
    Export-Csv -InputObject @() -Path ".\output\ec2-server-specs.csv" -NoTypeInformation
    exit 0
}
Write-Host ""

# --- Step 6: AWS CLI - Describe Instance Types ---
$stepStart = Get-Date
$instanceTypes = $instances | Select-Object -ExpandProperty InstanceType -Unique
Write-Host "[Step 6/8] Calling AWS EC2 describe-instance-types ($($instanceTypes.Count) unique types)..." -ForegroundColor Yellow

$specs = aws ec2 describe-instance-types `
  --instance-types $instanceTypes `
  --query "InstanceTypes[].{InstanceType:InstanceType,VCpus:VCpuInfo.DefaultVCpus,MemoryMB:MemoryInfo.SizeInMiB}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart

if (-not $specs) {
    Write-Host "[Step 6/8] WARNING: describe-instance-types failed. vCPU/Memory data will be missing." -ForegroundColor Red
} else {
    Write-Host "[Step 6/8] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
}

# Build a lookup hashtable for specs
$specsLookup = @{}
if ($specs) {
    foreach ($s in $specs) {
        $specsLookup[$s.InstanceType] = @{
            VCpus = $s.VCpus
            MemoryGB = [math]::Round($s.MemoryMB / 1024, 1)
        }
    }
}
Write-Host ""

# --- Step 7: AWS CLI - Describe Volumes ---
$stepStart = Get-Date
$instanceIds = @($instances | Select-Object -ExpandProperty InstanceId)
Write-Host "[Step 7/8] Calling AWS EC2 describe-volumes (filtered to $($instanceIds.Count) instances)..." -ForegroundColor Yellow
Write-Host "         Fetching EBS volumes attached to project instances only." -ForegroundColor Gray

$volumes = aws ec2 describe-volumes `
  --filters "Name=attachment.instance-id,Values=$($instanceIds -join ',')" `
  --query "Volumes[].{VolumeId:VolumeId,Size:Size,Device:Attachments[0].Device,InstanceId:Attachments[0].InstanceId}" `
  --output json | ConvertFrom-Json

$elapsed = (Get-Date) - $stepStart
$volCount = if ($volumes) { $volumes.Count } else { 0 }

if (-not $volumes) {
    Write-Host "[Step 7/8] WARNING: describe-volumes failed or no volumes found. Disk info will show N/A." -ForegroundColor Red
} else {
    Write-Host "[Step 7/8] Done. Retrieved $volCount volumes. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
}

# Build disk lookup by instance ID
$diskLookup = @{}
if ($volumes) {
    foreach ($v in $volumes) {
        if ($v.InstanceId) {
            if (-not $diskLookup.ContainsKey($v.InstanceId)) {
                $diskLookup[$v.InstanceId] = @()
            }
            $diskLookup[$v.InstanceId] += "$($v.Device) $($v.Size)GB"
        }
    }
}
Write-Host ""

# --- Step 8: Build Results & Export ---
$stepStart = Get-Date
Write-Host "[Step 8/8] Building results and exporting to CSV..." -ForegroundColor Yellow

$results = foreach ($inst in $instances) {
    $specInfo = if ($specsLookup.ContainsKey($inst.InstanceType)) { $specsLookup[$inst.InstanceType] } else { $null }
    $disks = if ($diskLookup.ContainsKey($inst.InstanceId)) {
        ($diskLookup[$inst.InstanceId]) -join ", "
    } else { "N/A" }

    [PSCustomObject]@{
        Name         = if ($inst.Name) { $inst.Name } else { "N/A" }
        Platform     = if ($inst.Platform) { $inst.Platform } else { "Linux/UNIX" }
        InstanceType = $inst.InstanceType
        VCpus        = if ($specInfo) { $specInfo.VCpus } else { "N/A" }
        MemoryGB     = if ($specInfo) { $specInfo.MemoryGB } else { "N/A" }
        Disks        = $disks
    }
}

$results | Export-Csv -Path ".\output\ec2-server-specs.csv" -NoTypeInformation

$elapsed = (Get-Date) - $stepStart
Write-Host "[Step 8/8] Done. (took $($elapsed.TotalSeconds.ToString('F2'))s)" -ForegroundColor Green
Write-Host ""

# --- Summary ---
$totalElapsed = (Get-Date) - $scriptStart
Write-Host "=== Complete ===" -ForegroundColor Cyan
Write-Host "Output: output\ec2-server-specs.csv ($(@($results).Count) rows)" -ForegroundColor Cyan
Write-Host "Total time: $($totalElapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
