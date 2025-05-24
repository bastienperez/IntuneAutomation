<#
.TITLE
    Application Inventory Report

.SYNOPSIS
    Generate a comprehensive application inventory report for all managed devices in Intune.

.DESCRIPTION
    This script connects to Microsoft Graph, retrieves all managed devices and their installed applications,
    and generates detailed reports in both CSV and HTML formats. The report includes application details,
    installation status, version information, and summary statistics across the entire device fleet.

.TAGS
    Apps,Reporting,Devices

.MINROLE
    Intune Administrator

.PERMISSIONS
    DeviceManagementManagedDevices.Read.All,DeviceManagementApps.Read.All

.AUTHOR
    Ugur Koc

.VERSION
    1.0

.CHANGELOG
    1.0 - Initial release

.EXAMPLE
    .\get-application-inventory-report.ps1
    Generates application inventory reports for all managed devices

.EXAMPLE
    .\get-application-inventory-report.ps1 -OutputPath "C:\Reports" -IncludeSystemApps
    Generates reports including system applications and saves them to the specified directory

.EXAMPLE
    .\get-application-inventory-report.ps1 -FilterByPublisher "Microsoft Corporation" -OpenReport
    Generates reports filtered by Microsoft applications and opens the HTML report

.NOTES
    - Requires Microsoft.Graph.Authentication module: Install-Module Microsoft.Graph.Authentication
    - Requires appropriate permissions in Azure AD
    - Large tenants may take considerable time to complete due to API rate limits
    - Reports are saved in both CSV and HTML formats
    - System applications are excluded by default to focus on business applications
    - Uses beta endpoint for enhanced application data
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSystemApps,
    
    [Parameter(Mandatory = $false)]
    [string]$FilterByPublisher = "",
    
    [Parameter(Mandatory = $false)]
    [string]$FilterByAppName = "",
    
    [Parameter(Mandatory = $false)]
    [switch]$OpenReport,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxDevices = 0
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
    Write-Information "Connecting to Microsoft Graph..." -InformationAction Continue
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "DeviceManagementApps.Read.All" -NoWelcome
    Write-Information "✓ Successfully connected to Microsoft Graph" -InformationAction Continue
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    exit 1
}

# Function to get all pages of results with rate limiting
function Get-MgGraphAllPage {
    param(
        [string]$Uri,
        [int]$DelayMs = 100
    )
    
    $allResults = @()
    $nextLink = $Uri
    $requestCount = 0
    
    do {
        try {
            # Add delay to respect rate limits
            if ($requestCount -gt 0) {
                Start-Sleep -Milliseconds $DelayMs
            }
            
            $response = Invoke-MgGraphRequest -Uri $nextLink -Method GET
            $requestCount++
            
            if ($response.value) {
                $allResults += $response.value
            }
            else {
                $allResults += $response
            }
            
            $nextLink = $response.'@odata.nextLink'
            
            # Show progress for large datasets
            if ($requestCount % 10 -eq 0) {
                Write-Information "." -InformationAction Continue
            }
        }
        catch {
            if ($_.Exception.Message -like "*429*" -or $_.Exception.Message -like "*throttled*") {
                Write-Information "`nRate limit hit, waiting 60 seconds..." -InformationAction Continue
                Start-Sleep -Seconds 60
                continue
            }
            Write-Warning "Error fetching data from $nextLink : $($_.Exception.Message)"
            break
        }
    } while ($nextLink)
    
    return $allResults
}

# System applications to exclude by default
$SystemApps = @(
    "Microsoft.Windows.*",
    "Microsoft.VCLibs.*",
    "Microsoft.NET.*",
    "Microsoft.UI.*",
    "Microsoft.Services.*",
    "Microsoft.Advertising.*",
    "Microsoft.MicrosoftEdge.*",
    "Windows.*",
    "InputApp",
    "Microsoft.AAD.*",
    "Microsoft.AccountsControl",
    "Microsoft.AsyncTextService",
    "Microsoft.BioEnrollment",
    "Microsoft.CredDialogHost",
    "Microsoft.ECApp",
    "Microsoft.LockApp",
    "Microsoft.MicrosoftEdgeDevToolsClient",
    "Microsoft.Win32WebViewHost",
    "Microsoft.Windows.Apprep.ChxApp",
    "Microsoft.Windows.AssignedAccessLockApp",
    "Microsoft.Windows.CapturePicker",
    "Microsoft.Windows.CloudExperienceHost",
    "Microsoft.Windows.ContentDeliveryManager",
    "Microsoft.Windows.Cortana",
    "Microsoft.Windows.NarratorQuickStart",
    "Microsoft.Windows.ParentalControls",
    "Microsoft.Windows.PeopleExperienceHost",
    "Microsoft.Windows.PinningConfirmationDialog",
    "Microsoft.Windows.SecHealthUI",
    "Microsoft.Windows.SecureAssessmentBrowser",
    "Microsoft.Windows.ShellExperienceHost",
    "Microsoft.Windows.XGpuEjectDialog",
    "Microsoft.XboxGameCallableUI"
)

# Get all managed devices
try {
    Write-Information "Retrieving managed devices..." -InformationAction Continue
    $devicesUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices"
    if ($MaxDevices -gt 0) {
        $devicesUri += "?`$top=$MaxDevices"
    }
    $devices = Get-MgGraphAllPage -Uri $devicesUri
    Write-Information "`n✓ Found $($devices.Count) managed devices" -InformationAction Continue
}
catch {
    Write-Error "Failed to retrieve managed devices: $($_.Exception.Message)"
    exit 1
}

# Create application inventory array
$applicationInventory = @()
$processedDevices = 0
$totalApplications = 0

Write-Information "Processing device applications..." -InformationAction Continue

foreach ($device in $devices) {
    $processedDevices++
    Write-Progress -Activity "Processing Device Applications" -Status "Processing device $processedDevices of $($devices.Count): $($device.deviceName)" -PercentComplete (($processedDevices / $devices.Count) * 100)
    
    try {
        # Use the beta endpoint with expand to get detected apps for each device
        $deviceAppsUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.id)?`$expand=detectedApps"
        Write-Verbose "Processing device: $($device.deviceName) (ID: $($device.id))" -Verbose
        Write-Verbose "API URL: $deviceAppsUri" -Verbose
        $deviceWithApps = Invoke-MgGraphRequest -Uri $deviceAppsUri -Method GET
        
        if ($deviceWithApps.detectedApps) {
            foreach ($app in $deviceWithApps.detectedApps) {
                # Skip system apps if not included
                if (-not $IncludeSystemApps) {
                    $isSystemApp = $false
                    foreach ($systemApp in $SystemApps) {
                        if ($app.displayName -like $systemApp) {
                            $isSystemApp = $true
                            break
                        }
                    }
                    if ($isSystemApp) { continue }
                }
                
                # Apply filters if specified
                if ($FilterByPublisher -and $app.publisher -notlike "*$FilterByPublisher*") {
                    continue
                }
                
                if ($FilterByAppName -and $app.displayName -notlike "*$FilterByAppName*") {
                    continue
                }
                
                # Calculate days since last seen
                $daysSinceLastSeen = if ($device.lastSyncDateTime) {
                    [math]::Round(((Get-Date) - [DateTime]$device.lastSyncDateTime).TotalDays, 1)
                }
                else {
                    "Never"
                }
                
                # Create application inventory entry
                $appEntry = [PSCustomObject]@{
                    DeviceName          = $device.deviceName
                    DeviceId            = $device.id
                    UserPrincipalName   = $device.userPrincipalName
                    UserDisplayName     = $device.userDisplayName
                    OperatingSystem     = $device.operatingSystem
                    OSVersion           = $device.osVersion
                    ApplicationName     = $app.displayName
                    ApplicationVersion  = $app.version
                    Publisher           = if ($app.publisher) { $app.publisher } else { "Unknown" }
                    ApplicationSize     = if ($app.sizeInByte -and $app.sizeInByte -gt 0) { [math]::Round($app.sizeInByte / 1MB, 2) } else { "Unknown" }
                    ApplicationSizeUnit = if ($app.sizeInByte -and $app.sizeInByte -gt 0) { "MB" } else { "N/A" }
                    Platform            = if ($app.platform) { $app.platform } else { "Unknown" }
                    LastSyncDateTime    = $device.lastSyncDateTime
                    DaysSinceLastSync   = $daysSinceLastSeen
                    DeviceModel         = $device.model
                    DeviceManufacturer  = $device.manufacturer
                    EnrollmentType      = $device.managementState
                    OwnerType           = $device.managedDeviceOwnerType
                    ComplianceState     = $device.complianceState
                    ApplicationId       = $app.id
                }
                
                $applicationInventory += $appEntry
                $totalApplications++
            }
        }
        
        # Add a small delay to respect rate limits
        Start-Sleep -Milliseconds 100
    }
    catch {
        if ($_.Exception.Message -like "*429*" -or $_.Exception.Message -like "*throttled*") {
            Write-Information "`nRate limit hit, waiting 60 seconds..." -InformationAction Continue
            Start-Sleep -Seconds 60
            # Retry the same device
            $processedDevices--
            continue
        }
        Write-Warning "Error processing applications for device $($device.deviceName): $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Processing Device Applications" -Completed

# Generate summary statistics
$uniqueApplications = $applicationInventory | Group-Object ApplicationName | Measure-Object | Select-Object -ExpandProperty Count
$uniquePublishers = $applicationInventory | Group-Object Publisher | Measure-Object | Select-Object -ExpandProperty Count
$uniqueDevices = $applicationInventory | Group-Object DeviceName | Measure-Object | Select-Object -ExpandProperty Count

# Get top applications by device count
$topApplications = $applicationInventory | Group-Object ApplicationName | 
ForEach-Object { 
    [PSCustomObject]@{
        ApplicationName = $_.Name
        DeviceCount     = $_.Count
        UniqueVersions  = ($_.Group | Group-Object ApplicationVersion | Measure-Object).Count
        Publishers      = ($_.Group | Group-Object Publisher | Select-Object -First 1).Name
    }
} | Sort-Object DeviceCount -Descending | Select-Object -First 10

# Get top publishers by application count
$topPublishers = $applicationInventory | Group-Object Publisher | 
ForEach-Object { 
    [PSCustomObject]@{
        Publisher        = $_.Name
        ApplicationCount = ($_.Group | Group-Object ApplicationName | Measure-Object).Count
        DeviceCount      = $_.Count
    }
} | Sort-Object ApplicationCount -Descending | Select-Object -First 10

# Generate timestamp for file names
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$csvPath = Join-Path $OutputPath "Intune_Application_Inventory_Report_$timestamp.csv"
$htmlPath = Join-Path $OutputPath "Intune_Application_Inventory_Report_$timestamp.html"

# Export to CSV
try {
    $applicationInventory | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Information "✓ CSV report saved: $csvPath" -InformationAction Continue
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
    <title>Intune Application Inventory Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #0078d4; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background-color: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .summary-item { text-align: center; padding: 10px; background-color: #f8f9fa; border-radius: 4px; }
        .summary-number { font-size: 24px; font-weight: bold; color: #0078d4; }
        .top-lists { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 20px; }
        .top-list { background-color: white; padding: 15px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .top-list h3 { margin-top: 0; color: #0078d4; }
        .top-item { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #e1e5e9; }
        .top-item:last-child { border-bottom: none; }
        table { width: 100%; border-collapse: collapse; background-color: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background-color: #0078d4; color: white; padding: 12px; text-align: left; font-weight: 600; position: sticky; top: 0; }
        td { padding: 10px 12px; border-bottom: 1px solid #e1e5e9; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        tr:hover { background-color: #e3f2fd; }
        .footer { margin-top: 20px; text-align: center; color: #6c757d; font-size: 12px; }
        .filter-info { background-color: #fff3cd; border: 1px solid #ffeaa7; padding: 10px; border-radius: 4px; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Intune Application Inventory Report</h1>
        <p>Generated on: $(Get-Date -Format "dddd, MMMM dd, yyyy 'at' HH:mm:ss")</p>
    </div>
"@

    # Add filter information if filters were applied
    if ($FilterByPublisher -or $FilterByAppName -or $IncludeSystemApps -or $MaxDevices -gt 0) {
        $htmlContent += "<div class='filter-info'><strong>Applied Filters:</strong> "
        if ($FilterByPublisher) { $htmlContent += "Publisher: $FilterByPublisher | " }
        if ($FilterByAppName) { $htmlContent += "Application: $FilterByAppName | " }
        if ($IncludeSystemApps) { $htmlContent += "Including System Apps | " }
        if ($MaxDevices -gt 0) { $htmlContent += "Max Devices: $MaxDevices | " }
        $htmlContent = $htmlContent.TrimEnd(" | ") + "</div>"
    }

    $htmlContent += @"
    <div class="summary">
        <h2>Summary</h2>
        <div class="summary-grid">
            <div class="summary-item">
                <div class="summary-number">$totalApplications</div>
                <div>Total Application Instances</div>
            </div>
            <div class="summary-item">
                <div class="summary-number">$uniqueApplications</div>
                <div>Unique Applications</div>
            </div>
            <div class="summary-item">
                <div class="summary-number">$uniquePublishers</div>
                <div>Unique Publishers</div>
            </div>
            <div class="summary-item">
                <div class="summary-number">$uniqueDevices</div>
                <div>Devices with Applications</div>
            </div>
        </div>
        
        <div class="top-lists">
            <div class="top-list">
                <h3>Top 10 Applications by Device Count</h3>
"@

    foreach ($app in $topApplications) {
        $htmlContent += "<div class='top-item'><span>$($app.ApplicationName)</span><span>$($app.DeviceCount) devices</span></div>"
    }

    $htmlContent += @"
            </div>
            <div class="top-list">
                <h3>Top 10 Publishers by Application Count</h3>
"@

    foreach ($publisher in $topPublishers) {
        $htmlContent += "<div class='top-item'><span>$($publisher.Publisher)</span><span>$($publisher.ApplicationCount) apps</span></div>"
    }

    $htmlContent += @"
            </div>
        </div>
    </div>
    
    <div class="summary">
        <h2>Detailed Application Inventory</h2>
        <table>
            <thead>
                <tr>
                    <th>Device Name</th>
                    <th>User</th>
                    <th>Application Name</th>
                    <th>Version</th>
                    <th>Publisher</th>
                    <th>Platform</th>
                    <th>Size (MB)</th>
                    <th>OS</th>
                    <th>Last Sync</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($app in $applicationInventory | Sort-Object DeviceName, ApplicationName) {
        $sizeDisplay = if ($app.ApplicationSize -ne "Unknown") { "$($app.ApplicationSize) $($app.ApplicationSizeUnit)" } else { "Unknown" }
        $htmlContent += @"
                <tr>
                    <td>$($app.DeviceName)</td>
                    <td>$($app.UserDisplayName)</td>
                    <td>$($app.ApplicationName)</td>
                    <td>$($app.ApplicationVersion)</td>
                    <td>$($app.Publisher)</td>
                    <td>$($app.Platform)</td>
                    <td>$sizeDisplay</td>
                    <td>$($app.OperatingSystem) $($app.OSVersion)</td>
                    <td>$($app.LastSyncDateTime)</td>
                </tr>
"@
    }

    $htmlContent += @"
            </tbody>
        </table>
    </div>
    
    <div class='footer'>Report generated by Intune Application Inventory Script v1.0</div>
</body>
</html>
"@

    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Information "✓ HTML report saved: $htmlPath" -InformationAction Continue
    
    if ($OpenReport) {
        Start-Process $htmlPath
    }
}
catch {
    Write-Error "Failed to generate HTML report: $($_.Exception.Message)"
}

# Display summary
Write-Output ""
Write-Information "📱 APPLICATION INVENTORY SUMMARY" -InformationAction Continue
Write-Information "=================================" -InformationAction Continue
Write-Information "Total Application Instances: $totalApplications" -InformationAction Continue
Write-Information "Unique Applications: $uniqueApplications" -InformationAction Continue
Write-Information "Unique Publishers: $uniquePublishers" -InformationAction Continue
Write-Information "Devices Processed: $uniqueDevices" -InformationAction Continue

if ($topApplications.Count -gt 0) {
    Write-Information "`nTop 5 Most Common Applications:" -InformationAction Continue
    $topApplications | Select-Object -First 5 | ForEach-Object {
        Write-Information "  • $($_.ApplicationName): $($_.DeviceCount) devices" -InformationAction Continue
    }
}

Write-Information "`nReports saved to:" -InformationAction Continue
Write-Information "📄 CSV: $csvPath" -InformationAction Continue
Write-Information "🌐 HTML: $htmlPath" -InformationAction Continue

# Disconnect from Microsoft Graph
try {
    Disconnect-MgGraph | Out-Null
    Write-Information "`n✓ Disconnected from Microsoft Graph" -InformationAction Continue
}
catch {
    Write-Warning "Could not disconnect from Microsoft Graph: $($_.Exception.Message)"
}

Write-Information "`n🎉 Application inventory report generation completed successfully!" -InformationAction Continue 