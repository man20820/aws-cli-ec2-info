# ============================================
# AWS Infrastructure Information Gathering
# Output: CSV files for customer handover
# ============================================

# --- EC2 Instances ---
# Columns: Name, Private IP, Instance Type, Environment Tag
# Filtered by Project tag (user input)

$projectTag = Read-Host "Enter the Project tag value to filter EC2 instances"

if ([string]::IsNullOrWhiteSpace($projectTag)) {
    Write-Host "Error: Project tag cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host "Gathering EC2 instances with Project tag: $projectTag ..."

# Ensure output directory exists
if (-not (Test-Path ".\output")) { New-Item -ItemType Directory -Path ".\output" | Out-Null }

$allInstances = aws ec2 describe-instances `
  --query "Reservations[].Instances[?State.Name!='terminated'].{Name:Tags[?Key=='Name']|[0].Value,PrivateIP:PrivateIpAddress,InstanceType:InstanceType,Environment:Tags[?Key=='Environment']|[0].Value,Project:Tags[?Key=='Project']|[0].Value}" `
  --output json | ConvertFrom-Json

if (-not $allInstances) {
    Write-Host "Error: AWS CLI call failed or no instances found." -ForegroundColor Red
    exit 1
}

$filtered = $allInstances | Where-Object { $_.Project -eq $projectTag }

if ($filtered.Count -eq 0) {
    Write-Host "Warning: No instances found with Project tag '$projectTag'" -ForegroundColor Yellow
    Write-Host "Checking available Project tag values..."
    $allProjects = $allInstances | Select-Object -ExpandProperty Project -Unique | Where-Object { $_ }
    if ($allProjects) {
        Write-Host "Available Project tags: $($allProjects -join ', ')"
    } else {
        Write-Host "No instances have a 'Project' tag. Check if your tag key is exactly 'Project' (case-sensitive)."
    }
}

$filtered | Select-Object Name, PrivateIP, InstanceType, Environment |
  Export-Csv -Path ".\output\ec2-instances.csv" -NoTypeInformation

Write-Host "Done! Output: output\ec2-instances.csv"
