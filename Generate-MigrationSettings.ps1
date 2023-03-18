<#
  .SYNOPSIS
  Builds a JSON file containing migration settings

  .DESCRIPTION
  Generates default values for settings required for sites migration based on parameters passed for use with Invoke-SiteMigration

  .PARAMETER SitePackageResultsPath
  Specifies the path to a file containing sites packaging details
  Settings are generated for all sites in this SitePackageResultsPath that specify a package path 
  
  .PARAMETER Region
  Specifies a region to be used for all sites migration   

  .PARAMETER SubscriptionId
  Specifies an Azure subscription to use for all sites migration

  .PARAMETER ResourceGroup
  Specifies a Resource Group to use for all sites migration

  .PARAMETER AppServiceEnvironment
  Specifies App Service Environment to use for all sites migration

  .PARAMETER MigrationSettingsFilePath
  Specifies the path where the migration settings file will be saved

  .PARAMETER Force
  Overwrites the migrations settings file if already exists

  .OUTPUTS
  Generate-MigrationSettings.ps1 outputs the path to a file containing Default settings for migration

  .EXAMPLE
  C:\PS> .\Generate-MigrationSettings -SitePackageResultsPath PackageResults.json -Region "West US" -SubscriptionId "01234567-3333-4444-5555-111111111111" -ResourceGroup "MyResourceGroup"  

  .EXAMPLE
  C:\PS> .\Generate-MigrationSettings -SitePackageResultsPath PackageResults.json -Region "West US" -SubscriptionId "01234567-3333-4444-5555-111111111111" -ResourceGroup "MyResourceGroup" -AppServiceEnvironment "MyASE" -MigrationSettingsFilePath "C:\Migration\MyMigrationSettings.json"
#>

#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$SitePackageResultsPath,

    [Parameter(Mandatory)]
    [string]$Region,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$AppServiceEnvironment,

    [Parameter()]
    [string]$MigrationSettingsFilePath,

    [Parameter()]
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot "MigrationHelperFunctions.psm1")

$ScriptConfig = Get-ScriptConfig
$MigrationSettings = New-Object System.Collections.ArrayList

Send-TelemetryEventIfEnabled -TelemetryTitle "Generate-MigrationSettings.ps1" -EventName "Started script" -EventType "action" -ErrorAction SilentlyContinue

if  (!$MigrationSettingsFilePath) {
    $MigrationSettingsFilePath = $ScriptConfig.DefaultMigrationSettingsFilePath
}

if (Test-Path $MigrationSettingsFilePath) {
    if($Force) {
        Write-HostInfo -Message "Existing $MigrationSettingsFilePath file will be overwritten"
    } else {
        Write-HostError -Message  "$MigrationSettingsFilePath already exists. Use -Force to overwrite or specify alternate location with MigrationSettingsFilePath parameter"
        exit 1
    }
} 

Initialize-LoginToAzure

#validations on azure parameters before adding them as part of settings file
try {
    Test-AzureResources -SubscriptionId $SubscriptionId -Region $Region -AppServiceEnvironment $AppServiceEnvironment -ResourceGroup $ResourceGroup 
} catch {
    #non termination error as validations are carried in migration (Invoke-SiteMigration.ps1) step too
    Write-HostError "Error in validating Azure parameters: $($_.Exception.Message)"
}

function Get-IfP1V3Available {
    try {
        $AccessToken = Get-AzureAccessToken
        $Headers = @{
            'Content-Type' = 'application/json'
            'Authorization' = "Bearer $AccessToken"
        }
        $RegionsForSkuURI = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Web/geoRegions?api-version=2020-10-01&sku=PremiumV3"
        $RegionsForP1V3 = Invoke-RestMethod -Uri $RegionsForSkuURI -Method "GET" -Headers $Headers
        $RegionsData = $RegionsForP1V3.value
        foreach ($SkuRegion in $RegionsData) {
            $RegionName = $SkuRegion.name -replace '\s',''
            if ($RegionName -eq $Region) {
                return $true
            }
        }
    }
    catch {
        Write-HostWarn -Message "Error finding if PremiumV3 Tier is available for region  $Region : $($_.Exception.Message)"  
        Send-TelemetryEventIfEnabled -TelemetryTitle "Generate-MigrationSettings.ps1" -EventName "Error in finding P1V3 availability" -EventType "error" -ErrorAction SilentlyContinue
    }
    
    return $false
}

try {
    $PackageResults = Get-Content $SitePackageResultsPath -Raw -ErrorAction Stop | ConvertFrom-Json
}
catch {
    Write-HostError "Error reading Site package results file: $($_.Exception.Message)"
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Send-TelemetryEventIfEnabled -TelemetryTitle "Generate-MigrationSettings.ps1" -EventName "Error reading migration settings file" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}

$SitesPackageResults = @($PackageResults | Where-Object {($null -ne $_.SitePackagePath)})

if (!$SitesPackageResults -or ($SitesPackageResults.count -eq 0)) {
    Write-HostError -Message "No succesfully packaged site found in $SitePackageResultsPath"
    Write-HostInfo -Message "Run Get-SitePackage.ps1 to package site contents"
    exit 1
}

$TotalSites = $SitesPackageResults.count
$SitesPerASP = 8
$Tier = "PremiumV2"

if ($AppServiceEnvironment) {
    $SitesPerASP = 16
    $Tier = "IsolatedV2" 
    try {
        $AseDetails = Get-AzResource -Name $AppServiceEnvironment -ResourceType Microsoft.Web/hostingEnvironments -ErrorAction Stop
        if (!$AseDetails) {
            Write-HostError "App Service Environment $AppServiceEnvironment doesn't exist in Subscription $SubscriptionId"
            Write-HostError "Please provide an existing App Service Environment in Subscription $SubscriptionId"
            exit 1  
        }

        #Warning so that user can choose to modify Region parameter and make sure all their resources are within one region if they want to
        if($Region -and $AseDetails.Location -ne $Region) {
            Write-HostWarn "Region '$Region' provided is different from App Service Environment '$AppServiceEnvironment' region $($AseDetails.Location)"
            Write-HostWarn "Setting Region as '$($AseDetails.Location)' for migration"
            $Region = $AseDetails.Location
        }
                 
        $ASEDetailsWithVer = Get-AzAppServiceEnvironment -Name $AppServiceEnvironment -ResourceGroupName $ASEDetails.ResourceGroupName
        if($ASEDetailsWithVer.Kind -eq "ASEV2") {
            $SitesPerASP = 8
            $Tier = "Isolated" 
        } elseif (!$ASEDetailsWithVer.Kind) {
            Write-HostWarn "Unable to get ASE version information"                
        }
    }
    catch {
        Write-HostError -Message "Error verifying if App Service Environment is valid : $($_.Exception.Message)"
        exit 1  
    }            
} elseif (Get-IfP1V3Available) {
    $SitesPerASP = 16
    $Tier = "PremiumV3"
} 

Write-HostInfo -Message "Setting Default Tier as $Tier"
$ASPsToCreate = [int][Math]::Ceiling($TotalSites/$SitesPerASP)
$SiteIndex = 0;
while ($ASPsToCreate -gt 0) {
    $RandomNumber = Get-Random -Maximum 999999 -Minimum 000000
    $tStamp = Get-Date -format yyyyMMdd
    $ASPName = "Migration_ASP_" + $tStamp+ "_" + $RandomNumber

    $MigrationSetting = New-Object PSObject

    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name AppServicePlan -Value $ASPName
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name SubscriptionId -Value $SubscriptionId
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name Region -Value $Region
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name ResourceGroup -Value $ResourceGroup
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name Tier -Value $Tier
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name NumberOfWorkers -Value $ScriptConfig.ASPNumberOfWorkers
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name WorkerSize -Value $ScriptConfig.ASPWorkerSize
    if ($AppServiceEnvironment) {
        Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name AppServiceEnvironment -Value $AppServiceEnvironment
    }
    
    $SitesSettings = New-Object System.Collections.ArrayList
    
    $ASPCapacity = $SitesPerASP
    while ($ASPCapacity -gt 0 -and $SiteIndex -lt $TotalSites) {
        $Site = $SitesPackageResults[$SiteIndex]
        $SitePackagePath = $Site.SitePackagePath
        # get full path to package files, if path is relative should be relative to package results file 
        if(-not ([System.IO.Path]::IsPathRooted($SitePackagePath))) {       
            $packageFileFullPath = $SitePackageResultsPath
            if(-not ([System.IO.Path]::IsPathRooted($packageFileFullPath))) {
                $packageFileFullPath = Join-Path (Get-Location).Path $SitePackageResultsPath
            }
            $SitePackagePath = Join-Path (Split-Path -Path $packageFileFullPath) $Site.SitePackagePath
        }
        $SiteSetting = New-Object PSObject

        Add-Member -InputObject $SiteSetting -MemberType NoteProperty -Name IISSiteName -Value $Site.SiteName
        Add-Member -InputObject $SiteSetting -MemberType NoteProperty -Name SitePackagePath -Value $SitePackagePath
        Add-Member -InputObject $SiteSetting -MemberType NoteProperty -Name AzureSiteName -Value $Site.SiteName
        [void]$SitesSettings.Add($SiteSetting)

        $ASPCapacity--
        $SiteIndex++

    }
    Add-Member -InputObject $MigrationSetting -MemberType NoteProperty -Name Sites -Value $SitesSettings
    [void]$MigrationSettings.Add($MigrationSetting)
    $ASPsToCreate--
}

try {
    ConvertTo-Json $MigrationSettings -Depth 10 | Out-File (New-Item -Path $MigrationSettingsFilePath -ErrorAction Stop -Force)
}
catch {
    Write-HostError -Message "Error creating migration settings file: $($_.Exception.Message)" 
    Send-TelemetryEventIfEnabled -TelemetryTitle "Generate-MigrationSettings.ps1" -EventName "Error in creating migration settings file" -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}

Write-HostInfo "Migration settings have been successfully created and written to $MigrationSettingsFilePath"
Send-TelemetryEventIfEnabled -TelemetryTitle "Generate-MigrationSettings.ps1" -EventName "Script end" -EventType "action" -ErrorAction SilentlyContinue
return  $MigrationSettingsFilePath
# SIG # Begin signature block
# MIInogYJKoZIhvcNAQcCoIInkzCCJ48CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA46spqQ4/vHZ9p
# jTfl013Q6qM+g2foMn/aGHU0lmIpUaCCDXYwggX0MIID3KADAgECAhMzAAACy7d1
# OfsCcUI2AAAAAALLMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjIwNTEyMjA0NTU5WhcNMjMwNTExMjA0NTU5WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC3sN0WcdGpGXPZIb5iNfFB0xZ8rnJvYnxD6Uf2BHXglpbTEfoe+mO//oLWkRxA
# wppditsSVOD0oglKbtnh9Wp2DARLcxbGaW4YanOWSB1LyLRpHnnQ5POlh2U5trg4
# 3gQjvlNZlQB3lL+zrPtbNvMA7E0Wkmo+Z6YFnsf7aek+KGzaGboAeFO4uKZjQXY5
# RmMzE70Bwaz7hvA05jDURdRKH0i/1yK96TDuP7JyRFLOvA3UXNWz00R9w7ppMDcN
# lXtrmbPigv3xE9FfpfmJRtiOZQKd73K72Wujmj6/Su3+DBTpOq7NgdntW2lJfX3X
# a6oe4F9Pk9xRhkwHsk7Ju9E/AgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUrg/nt/gj+BBLd1jZWYhok7v5/w4w
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzQ3MDUyODAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAJL5t6pVjIRlQ8j4dAFJ
# ZnMke3rRHeQDOPFxswM47HRvgQa2E1jea2aYiMk1WmdqWnYw1bal4IzRlSVf4czf
# zx2vjOIOiaGllW2ByHkfKApngOzJmAQ8F15xSHPRvNMmvpC3PFLvKMf3y5SyPJxh
# 922TTq0q5epJv1SgZDWlUlHL/Ex1nX8kzBRhHvc6D6F5la+oAO4A3o/ZC05OOgm4
# EJxZP9MqUi5iid2dw4Jg/HvtDpCcLj1GLIhCDaebKegajCJlMhhxnDXrGFLJfX8j
# 7k7LUvrZDsQniJZ3D66K+3SZTLhvwK7dMGVFuUUJUfDifrlCTjKG9mxsPDllfyck
# 4zGnRZv8Jw9RgE1zAghnU14L0vVUNOzi/4bE7wIsiRyIcCcVoXRneBA3n/frLXvd
# jDsbb2lpGu78+s1zbO5N0bhHWq4j5WMutrspBxEhqG2PSBjC5Ypi+jhtfu3+x76N
# mBvsyKuxx9+Hm/ALnlzKxr4KyMR3/z4IRMzA1QyppNk65Ui+jB14g+w4vole33M1
# pVqVckrmSebUkmjnCshCiH12IFgHZF7gRwE4YZrJ7QjxZeoZqHaKsQLRMp653beB
# fHfeva9zJPhBSdVcCW7x9q0c2HVPLJHX9YCUU714I+qtLpDGrdbZxD9mikPqL/To
# /1lDZ0ch8FtePhME7houuoPcMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGYIwghl+AgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAALLt3U5+wJxQjYAAAAAAsswDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICLKMMv1liEvCoJOozBbzAJy
# U4+BpiIqSbJ7DPr/94JtMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAHdffpX6khxXwMPiMzEybVvBuYr5XSk3F8C9WXARREg/34ofZHUDhLnW4
# eH0iSpW+9LctCnC8kqo3jip08FGyCDF/jMZ5AHFtixYaFFrgDkTVEQ17ENNa25kc
# ZXu5PzfbrnQuCcO5Qn8LQ1K4mN/cUTL60XWmlhK8qGltLP90+RtyeQFpSZVCb/1o
# mYBkqc2mQNtilvlKBAs7Ds/n7VVHH/4Bb11DIEZNnY+vWHYbZ9tlvZnoUit0TPLb
# MMOPdr+LD1DoJiqlmN8SRX9o16/pYMlxMXmaEpI4SVfrjM0fkyz513s/1dbb/7w3
# 2sRzCf7OJbxYKkukm5ZbHCIBVGkMJ6GCFwwwghcIBgorBgEEAYI3AwMBMYIW+DCC
# FvQGCSqGSIb3DQEHAqCCFuUwghbhAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFVBgsq
# hkiG9w0BCRABBKCCAUQEggFAMIIBPAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCBs/kVO+B/HSZKxBzF2cNHkwNNA5vV8PdfKh8GsIiwJIAIGY3Os8HbI
# GBMyMDIyMTIwNjIzNTQ0Ni42NjdaMASAAgH0oIHUpIHRMIHOMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3Bl
# cmF0aW9ucyBQdWVydG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046Nzg4
# MC1FMzkwLTgwMTQxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZp
# Y2WgghFfMIIHEDCCBPigAwIBAgITMwAAAahV8GGpzDAYXAABAAABqDANBgkqhkiG
# 9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYw
# JAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMjAzMDIx
# ODUxMjNaFw0yMzA1MTExODUxMjNaMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSkwJwYDVQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVy
# dG8gUmljbzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046Nzg4MC1FMzkwLTgwMTQx
# JTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQCj2m3KwC4l1/KY8l6XDDfPSk73JpQIg8OK
# VPh3o2YYm1HqPx1Mvj/VcVoQl+6IHnijyeu+/i3lXT3RuYU7xg4ErqN8PgHJs3F2
# dkAhlIFEXi1Cm5q69OmwdMYb7WcKHpYcbT5IyRbG0xrUrflexOFQoz3WKkGf4jdA
# K115oGxH1cgsEvodrqKAYTOVHGz6ILa+VaYHc21DOP61rqZhVYzwdWrJ9/sL+2gQ
# ivI/UFCa6GOMtaZmUn9ErhjFmO3JtnL623Zu15XZY6kXR1vgkAAeBKojqoLpn0fm
# kqaOU++ShtPp7AZI5RkrFNQYteaeKz/PKWZ0qKe9xnpvRljthkS8D9eWBJyrHM8Y
# RmPmfDRGtEMDDIlZZLHT1OyeaivYMQEIzic6iEic4SMEFrRC6oCaB8JKk8Xpt4K2
# Owewzs0E50KSlqC9B1kfSqiL2gu4vV5T7/rnvPY/Xu35geJ4dYbpcxCc1+kTFPUx
# yTJWzujqz9zTRCiVvI4qQp8vB9X7r0rhX7ge7fviivYNnNjSruRM0rNZyjarZeCj
# t1M8ly1r00QzuA+T1UDnWtLao0vwFqFK8SguWT5ZCxPmD7EuRvhP1QoAmoIT8gWb
# BzSu8B5Un/9uroS5yqel0QCK6IhGJf+cltJkoY75wET69BiJUptCq6ksAo0eXJFk
# 9bCmhG/MNwIDAQABo4IBNjCCATIwHQYDVR0OBBYEFDbH2+Pi+FLrZTYfzMYxpI9J
# CyLVMB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYw
# VKBSoFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jv
# c29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcB
# AQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvY2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSku
# Y3J0MAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcN
# AQELBQADggIBAHE7gktkaqpn9pj6+jlMnYZlMfpur6RD7M1oqCV257EW58utpxfW
# F0yrkjVh9UBX8nP9jd2ExKeIRPGLYWCoAzPx1IVERF91k8BrHmLrg3ksVkSVgqKw
# BxdZMEMyCoK1HNxvrlcAJhvxCNRC0RMQOH7cdBIa3+fWiZuzp4J9JU0koilHrhgP
# jMuqAov1fBE8c/nm5b0ADWpbSYBn6abll2E+I4rEChE76CYwb+cfgQNKBBbu4Bmn
# jA5GY5zub3X+h3ip3iC7PWb8CFpIGEItmXqM28YJRuWMBMaIsXpMa0Uw2cDKJCGM
# V5nHLHENMV5ofiN76O4VfWTCk2vT2s+Z3uHHPDncNU/utuJgdFmlvRwBNYaIwegm
# 37p3bVf48MZnSodeaZSV5zdcjOzi/duB6gIiYrB2p6ThCeFJvW94RVFxNrhCS/Wm
# LiIJLFWCKtT9va0eF+5c97hCR+gjpKBOvlHGrjeiWBYITfSPCUQVgIR1+BkB5Z4L
# HX7Viy4g2TMp5YEQmc5GCNuDfXMfg9+u2MHJajWOgmbgIM8MtdrkWBUGrGB2CtYa
# c8k7biPwNgfHBvhzOl9Y39nfbgEcB+voS5D7bd/+TQZS16TpeYmckZQYu4g15FjW
# t47hnywCdyEg8jYe8rvh+MkGMkbPzFawpFlCbPRIryyrDSdgfyIza0rWMIIHcTCC
# BVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0BAQsFADCBiDEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWlj
# cm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMw
# MTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOThpkzntHIhC3mi
# y9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+
# Slr+uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ3MFEyHFcUTE3
# oAo4bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+
# tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYtcI4xyDUoveO0
# hyTD4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXAhjBcTyziYrLN
# ueKNiOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZ
# nkXftnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n
# 6Jl8P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC
# 4jMYctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh8zYGNRiER9vc
# G9H9stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8FdsaN8cIFRg/eKtF
# tvUeh17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkrBgEEAYI3FQEE
# BQIDAQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNV
# HQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3
# TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkG
# CSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8E
# BTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCd
# VX38Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQ
# dTltuw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOwBb6J6Gngugnu
# e99qb74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jfZfakVqr3lbYo
# VSfQJL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ5/ALaoHCgRlC
# GVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZ
# lvSP9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/
# ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6OEuabvshVGtq
# RRFHqfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+
# y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6TPmb/wrpNPgk
# NWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784cETRkPHIqzqK
# Oghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCAtIwggI7AgEBMIH8oYHU
# pIHRMIHOMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSkwJwYD
# VQQLEyBNaWNyb3NvZnQgT3BlcmF0aW9ucyBQdWVydG8gUmljbzEmMCQGA1UECxMd
# VGhhbGVzIFRTUyBFU046Nzg4MC1FMzkwLTgwMTQxJTAjBgNVBAMTHE1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAGy6/MSfQQeKy+GI
# OfF9S2eYkHcsoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# DQYJKoZIhvcNAQEFBQACBQDnOdpyMCIYDzIwMjIxMjA2MTkxMjUwWhgPMjAyMjEy
# MDcxOTEyNTBaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOc52nICAQAwCgIBAAIC
# EoYCAf8wBwIBAAICE2IwCgIFAOc7K/ICAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYK
# KwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUF
# AAOBgQCLckLzMv9tlBnjTg/g1zbgEI32zMdUZpM3yy0uj8MK4CMwSHQ5/WKvsobe
# KWUfVNQLryOteyJ60oQJBM8f0u9YcOcQwpcRzvEC9UAKCMh19N67xrpzo9Ba3t0n
# VJNYrILRW3nMZZJotpdHPTOMQlnhV2kjQBmnqvdgtgyXwi7c8DGCBA0wggQJAgEB
# MIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAABqFXwYanMMBhc
# AAEAAAGoMA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcN
# AQkQAQQwLwYJKoZIhvcNAQkEMSIEIDTaWwrHYb6XNIbJZURjeB7rb9ReFzwxdVyP
# E5dWWR+BMIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgdP7LHQDLB8JzcIXx
# QVz5RZ0b1oR6kl/WC1MQQ5dcZaYwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAahV8GGpzDAYXAABAAABqDAiBCBBBxvBSgnLzD69NM/T
# Sf3W2DFqHRSB8yB6mEnkhAlD7zANBgkqhkiG9w0BAQsFAASCAgCM0z52JBQySjFm
# sikS+HRlL29rAsBYHO4vhmzrgT6HFQBos0IvOURqb88DzXIUB4h448lQeRV/i/eE
# 5+DS4qYPx8AT8wMxbAr/0ep8K2Sz7r5pC2EoW2+N5UoH05UiIgxBFKsvPFmUjWxS
# 93Z5iGNnQmEuaOQLMLhweYfs3/xL1Qsbb3Xpu0epG1WMYQItS4neZVmUeQ4GrEoV
# f6YUq7C+2fpEtTrsyhm75fBNjfQGQjbJPFR13os+X7modAVCTktlNIakBl6Y5MUC
# Zk1b5LG54I3SGLIV0TxtGO1bRDd1tx30snqbVsKy2AJ9yT9zGgx5TLwW5ZaY255R
# MNSep/U8GxqySLYzn2NWDC9N5Wnm7neecM+fooatQ33SKJgQ049fhuR4mpred1QL
# 9F0ApSS5SyLJ3Uq3+mF1u54snZSmQ9+c3cKDHPu9CFR+4SagAI7pOhfGH0LetDsR
# cgGGfR4/rlFf0sMHwumZ51bCCxr+NAk6RcNMbtk76HHI49kGuzEIp+bxQSIpzN0V
# gJqcH60GpgWl3zGJV9iM2k93/Tt91R8Zpo6jd4yU8JhURAfLf9bgsrlux5CT6sty
# qA+sa91f6R/bJCDqlvkglxvqxdUzJyRm0n+IpI6t3zYZvOMGIDKVi8Itth7F7gSG
# Bd/QXclhY9rV9czp4YVKGoRYcANpgw==
# SIG # End signature block
