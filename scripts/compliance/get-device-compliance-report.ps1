<#
.SYNOPSIS
    Generate a comprehensive device compliance report for managed devices in Intune.

.DESCRIPTION
    This script connects to Microsoft Graph, retrieves managed devices and their compliance status,
    and generates a detailed report in both CSV and HTML formats. The report includes device details,
    compliance status, and summary statistics.

.TAGS
    Devices,Compliance,Reporting

.MINROLE
    Intune Administrator

.TESTEDPLATFORMS
    Windows 10,Windows 11,macOS,iOS,Android

.PERMISSIONS
    DeviceManagementManagedDevices.Read.All,DeviceManagementConfiguration.Read.All

.AUTHOR
    Ugur Koc

.VERSION
    1.0

.EXAMPLE
    .\get-device-compliance-report.ps1
    Generates compliance reports for all managed devices

.EXAMPLE
    .\get-device-compliance-report.ps1 -OutputPath "C:\Reports"
    Generates reports and saves them to the specified directory

.NOTES
    - Requires Microsoft.Graph.Authentication module: Install-Module Microsoft.Graph.Authentication
    - Requires appropriate permissions in Azure AD
    - Large tenants may take several minutes to complete
    - Reports are saved in both CSV and HTML formats
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory = $false)]
    [switch]$OpenReport
)

# Check if required module is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Error "Microsoft.Graph.Authentication module is required. Install it using: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    exit 1
}

# Import required module
Import-Module Microsoft.Graph.Authentication

# Connect to Microsoft Graph
try {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All" -NoWelcome
    Write-Host "✓ Successfully connected to Microsoft Graph" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    exit 1
}

# Function to get all pages of results
function Get-MgGraphAllPages {
    param(
        [string]$Uri
    )
    
    $allResults = @()
    $nextLink = $Uri
    
    do {
        try {
            $response = Invoke-MgGraphRequest -Uri $nextLink -Method GET
            
            if ($response.value) {
                $allResults += $response.value
            }
            else {
                $allResults += $response
            }
            
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Warning "Error fetching data from $nextLink : $($_.Exception.Message)"
            break
        }
    } while ($nextLink)
    
    return $allResults
}

# Get all managed devices
try {
    Write-Host "Retrieving managed devices..." -ForegroundColor Cyan
    $devices = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
    Write-Host "✓ Found $($devices.Count) managed devices" -ForegroundColor Green
}
catch {
    Write-Error "Failed to retrieve managed devices: $($_.Exception.Message)"
    exit 1
}

# Get compliance policies
try {
    Write-Host "Retrieving compliance policies..." -ForegroundColor Cyan
    $compliancePolicies = Get-MgGraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies"
    Write-Host "✓ Found $($compliancePolicies.Count) compliance policies" -ForegroundColor Green
}
catch {
    Write-Warning "Could not retrieve compliance policies: $($_.Exception.Message)"
    $compliancePolicies = @()
}

# Create report array
$report = @()
$processedCount = 0

Write-Host "Processing device compliance data..." -ForegroundColor Cyan

foreach ($device in $devices) {
    $processedCount++
    Write-Progress -Activity "Processing Devices" -Status "Processing device $processedCount of $($devices.Count)" -PercentComplete (($processedCount / $devices.Count) * 100)
    
    try {
        # Get device compliance details
        $complianceUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices('$($device.id)')/deviceCompliancePolicyStates"
        $deviceCompliance = Get-MgGraphAllPages -Uri $complianceUri
        
        # Calculate compliance summary
        $compliantPolicies = ($deviceCompliance | Where-Object { $_.state -eq "compliant" }).Count
        $nonCompliantPolicies = ($deviceCompliance | Where-Object { $_.state -eq "nonCompliant" }).Count
        $errorPolicies = ($deviceCompliance | Where-Object { $_.state -eq "error" }).Count
        $totalPolicies = $deviceCompliance.Count
        
        # Determine overall compliance status
        $overallCompliance = if ($nonCompliantPolicies -gt 0 -or $errorPolicies -gt 0) { 
            "Non-Compliant" 
        }
        elseif ($compliantPolicies -gt 0) { 
            "Compliant" 
        }
        else { 
            "Unknown" 
        }
        
        # Calculate days since last sync
        $daysSinceSync = if ($device.lastSyncDateTime) {
            [math]::Round(((Get-Date) - [DateTime]$device.lastSyncDateTime).TotalDays, 1)
        }
        else {
            "Never"
        }
        
        # Create device report object
        $deviceInfo = [PSCustomObject]@{
            DeviceName                              = $device.deviceName
            UserPrincipalName                       = $device.userPrincipalName
            UserDisplayName                         = $device.userDisplayName
            OperatingSystem                         = $device.operatingSystem
            OSVersion                               = $device.osVersion
            Model                                   = $device.model
            Manufacturer                            = $device.manufacturer
            SerialNumber                            = $device.serialNumber
            OverallCompliance                       = $overallCompliance
            CompliantPolicies                       = $compliantPolicies
            NonCompliantPolicies                    = $nonCompliantPolicies
            ErrorPolicies                           = $errorPolicies
            TotalPolicies                           = $totalPolicies
            LastSyncDateTime                        = $device.lastSyncDateTime
            DaysSinceLastSync                       = $daysSinceSync
            EnrolledDateTime                        = $device.enrolledDateTime
            ManagementState                         = $device.managementState
            OwnerType                               = $device.managedDeviceOwnerType
            ComplianceGracePeriodExpirationDateTime = $device.complianceGracePeriodExpirationDateTime
            DeviceId                                = $device.id
        }
        
        $report += $deviceInfo
        
    }
    catch {
        Write-Warning "Error processing device $($device.deviceName): $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Processing Devices" -Completed

# Generate timestamp for file names
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$csvPath = Join-Path $OutputPath "Intune_Device_Compliance_Report_$timestamp.csv"
$htmlPath = Join-Path $OutputPath "Intune_Device_Compliance_Report_$timestamp.html"

# Export to CSV
try {
    $report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "✓ CSV report saved: $csvPath" -ForegroundColor Green
}
catch {
    Write-Error "Failed to save CSV report: $($_.Exception.Message)"
}

# Generate HTML report
try {
    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Intune Device Compliance Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background-color: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }
        .summary-item { text-align: center; padding: 10px; background-color: #f8f9fa; border-radius: 4px; }
        .summary-number { font-size: 24px; font-weight: bold; color: #0078d4; }
        table { width: 100%; border-collapse: collapse; background-color: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background-color: #0078d4; color: white; padding: 12px; text-align: left; font-weight: 600; }
        td { padding: 10px 12px; border-bottom: 1px solid #e1e5e9; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        tr:hover { background-color: #e3f2fd; }
        .compliant { color: #28a745; font-weight: bold; }
        .non-compliant { color: #dc3545; font-weight: bold; }
        .unknown { color: #6c757d; font-weight: bold; }
        .footer { margin-top: 20px; text-align: center; color: #6c757d; font-size: 12px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Intune Device Compliance Report</h1>
        <p>Generated on: $(Get-Date -Format "dddd, MMMM dd, yyyy 'at' HH:mm:ss")</p>
    </div>
    
    <div class="summary">
        <h2>Summary</h2>
        <div class="summary-grid">
            <div class="summary-item">
                <div class="summary-number">$($report.Count)</div>
                <div>Total Devices</div>
            </div>
            <div class="summary-item">
                <div class="summary-number">$(($report | Where-Object { $_.OverallCompliance -eq 'Compliant' }).Count)</div>
                <div>Compliant Devices</div>
            </div>
            <div class="summary-item">
                <div class="summary-number">$(($report | Where-Object { $_.OverallCompliance -eq 'Non-Compliant' }).Count)</div>
                <div>Non-Compliant Devices</div>
            </div>
            <div class="summary-item">
                <div class="summary-number">$(($report | Where-Object { $_.DaysSinceLastSync -ne 'Never' -and [double]$_.DaysSinceLastSync -gt 7 }).Count)</div>
                <div>Stale Devices (>7 days)</div>
            </div>
        </div>
    </div>
"@

    # Add table
    $htmlContent += "<table><thead><tr>"
    $htmlContent += "<th>Device Name</th><th>User</th><th>OS</th><th>Compliance Status</th><th>Compliant Policies</th><th>Non-Compliant Policies</th><th>Last Sync</th><th>Days Since Sync</th>"
    $htmlContent += "</tr></thead><tbody>"
    
    foreach ($device in $report | Sort-Object DeviceName) {
        $complianceClass = switch ($device.OverallCompliance) {
            "Compliant" { "compliant" }
            "Non-Compliant" { "non-compliant" }
            default { "unknown" }
        }
        
        $htmlContent += "<tr>"
        $htmlContent += "<td>$($device.DeviceName)</td>"
        $htmlContent += "<td>$($device.UserDisplayName)</td>"
        $htmlContent += "<td>$($device.OperatingSystem) $($device.OSVersion)</td>"
        $htmlContent += "<td class='$complianceClass'>$($device.OverallCompliance)</td>"
        $htmlContent += "<td>$($device.CompliantPolicies)</td>"
        $htmlContent += "<td>$($device.NonCompliantPolicies)</td>"
        $htmlContent += "<td>$($device.LastSyncDateTime)</td>"
        $htmlContent += "<td>$($device.DaysSinceLastSync)</td>"
        $htmlContent += "</tr>"
    }
    
    $htmlContent += "</tbody></table>"
    $htmlContent += "<div class='footer'>Report generated by Intune Device Compliance Script v1.0</div>"
    $htmlContent += "</body></html>"
    
    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Host "✓ HTML report saved: $htmlPath" -ForegroundColor Green
    
    if ($OpenReport) {
        Start-Process $htmlPath
    }
    
}
catch {
    Write-Error "Failed to generate HTML report: $($_.Exception.Message)"
}

# Display summary
Write-Host "`n" -NoNewline
Write-Host "📊 COMPLIANCE REPORT SUMMARY" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Yellow
Write-Host "Total Devices: " -NoNewline; Write-Host $report.Count -ForegroundColor Cyan
Write-Host "Compliant Devices: " -NoNewline; Write-Host ($report | Where-Object { $_.OverallCompliance -eq 'Compliant' }).Count -ForegroundColor Green
Write-Host "Non-Compliant Devices: " -NoNewline; Write-Host ($report | Where-Object { $_.OverallCompliance -eq 'Non-Compliant' }).Count -ForegroundColor Red
Write-Host "Unknown Status: " -NoNewline; Write-Host ($report | Where-Object { $_.OverallCompliance -eq 'Unknown' }).Count -ForegroundColor Yellow
Write-Host "Stale Devices (>7 days): " -NoNewline; Write-Host ($report | Where-Object { $_.DaysSinceLastSync -ne 'Never' -and [double]$_.DaysSinceLastSync -gt 7 }).Count -ForegroundColor Magenta

Write-Host "`nReports saved to:" -ForegroundColor Green
Write-Host "📄 CSV: $csvPath" -ForegroundColor White
Write-Host "🌐 HTML: $htmlPath" -ForegroundColor White

# Disconnect from Microsoft Graph
try {
    Disconnect-MgGraph | Out-Null
    Write-Host "`n✓ Disconnected from Microsoft Graph" -ForegroundColor Green
}
catch {
    Write-Warning "Could not disconnect from Microsoft Graph: $($_.Exception.Message)"
}

Write-Host "`n🎉 Device compliance report generation completed successfully!" -ForegroundColor Green 