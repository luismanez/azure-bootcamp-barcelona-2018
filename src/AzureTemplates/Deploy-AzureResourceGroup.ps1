#Requires -Version 3.0
#Requires -Module AzureRM.Resources
#Requires -Module Azure.Storage

Param(
    [string] $SubscriptionID = "09c96f87-1e5d-4e5c-8ffa-92cda699793c",
    [string] $ResourceGroupLocation = "North Europe",
    [string] $ResourceGroupName = "IvanLuisAzureBootcamp2018",	
    [string] $sqlServerName = "IvanLuisSqlServerAzBoot2018",
    [string] $sqlServerDbName = "webAppDB",
    [switch] $UploadArtifacts,
    [string] $StorageAccountName,
    [string] $StorageContainerName = $ResourceGroupName.ToLowerInvariant() + '-stageartifacts',
    [string] $TemplateFile = '.\azuredeploy.json',
    [string] $TemplateParametersFile = '.\azuredeploy.parameters.json',
    [string] $ArtifactStagingDirectory = '.',
    [string] $DSCSourceFolder = 'DSC',
    [switch] $ValidateOnly
)

try {
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(' ','_'), '3.0.0')
} catch { }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)
    Set-StrictMode -Off
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

$OptionalParameters = New-Object -TypeName Hashtable
$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))

if ($UploadArtifacts) {
    # Convert relative paths to absolute paths if needed
    $ArtifactStagingDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory))
    $DSCSourceFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $DSCSourceFolder))

    # Parse the parameter file and update the values of artifacts location and artifacts location SAS token if they are present
    $JsonParameters = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
    if (($JsonParameters | Get-Member -Type NoteProperty 'parameters') -ne $null) {
        $JsonParameters = $JsonParameters.parameters
    }
    $ArtifactsLocationName = '_artifactsLocation'
    $ArtifactsLocationSasTokenName = '_artifactsLocationSasToken'
    $OptionalParameters[$ArtifactsLocationName] = $JsonParameters | Select -Expand $ArtifactsLocationName -ErrorAction Ignore | Select -Expand 'value' -ErrorAction Ignore
    $OptionalParameters[$ArtifactsLocationSasTokenName] = $JsonParameters | Select -Expand $ArtifactsLocationSasTokenName -ErrorAction Ignore | Select -Expand 'value' -ErrorAction Ignore

    # Create DSC configuration archive
    if (Test-Path $DSCSourceFolder) {
        $DSCSourceFilePaths = @(Get-ChildItem $DSCSourceFolder -File -Filter '*.ps1' | ForEach-Object -Process {$_.FullName})
        foreach ($DSCSourceFilePath in $DSCSourceFilePaths) {
            $DSCArchiveFilePath = $DSCSourceFilePath.Substring(0, $DSCSourceFilePath.Length - 4) + '.zip'
            Publish-AzureRmVMDscConfiguration $DSCSourceFilePath -OutputArchivePath $DSCArchiveFilePath -Force -Verbose
        }
    }

    # Create a storage account name if none was provided
    if ($StorageAccountName -eq '') {
        $StorageAccountName = 'stage' + ((Get-AzureRmContext).Subscription.SubscriptionId).Replace('-', '').substring(0, 19)
    }

    $StorageAccount = (Get-AzureRmStorageAccount | Where-Object{$_.StorageAccountName -eq $StorageAccountName})

    # Create the storage account if it doesn't already exist
    if ($StorageAccount -eq $null) {
        $StorageResourceGroupName = 'ARM_Deploy_Staging'
        New-AzureRmResourceGroup -Location "$ResourceGroupLocation" -Name $StorageResourceGroupName -Force
        $StorageAccount = New-AzureRmStorageAccount -StorageAccountName $StorageAccountName -Type 'Standard_LRS' -ResourceGroupName $StorageResourceGroupName -Location "$ResourceGroupLocation"
    }

    # Generate the value for artifacts location if it is not provided in the parameter file
    if ($OptionalParameters[$ArtifactsLocationName] -eq $null) {
        $OptionalParameters[$ArtifactsLocationName] = $StorageAccount.Context.BlobEndPoint + $StorageContainerName
    }

    # Copy files from the local storage staging location to the storage account container
    New-AzureStorageContainer -Name $StorageContainerName -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1

    $ArtifactFilePaths = Get-ChildItem $ArtifactStagingDirectory -Recurse -File | ForEach-Object -Process {$_.FullName}
    foreach ($SourcePath in $ArtifactFilePaths) {
        Set-AzureStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($ArtifactStagingDirectory.length + 1) `
            -Container $StorageContainerName -Context $StorageAccount.Context -Force
    }

    # Generate a 4 hour SAS token for the artifacts location if one was not provided in the parameters file
    if ($OptionalParameters[$ArtifactsLocationSasTokenName] -eq $null) {
        $OptionalParameters[$ArtifactsLocationSasTokenName] = ConvertTo-SecureString -AsPlainText -Force `
            (New-AzureStorageContainerSASToken -Container $StorageContainerName -Context $StorageAccount.Context -Permission r -ExpiryTime (Get-Date).AddHours(4))
    }
}


### Sign in###
Clear-AzureProfile -Force
Write-Host "Logging in...";
Add-AzureRmAccount | Out-Null;
Set-AzureRmContext -SubscriptionID $SubscriptionID;

# Create or update the resource group using the specified template file and template parameters file
New-AzureRmResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -Force

##Create temporary storage account to upload the web app deploy package
$_artifactsLocationSasToken = "";
$WebappDeployStorageAccountName = "tempwebappstazboot2018"
$WebappDeployStorageAccountGeoLocation = "Standard_LRS"
$WebappDeployStorageContainerName = "webappcontent"
$WebappPackageName = "AzureWebApp.zip"
$DBPackageName = "DBbackup.bacpac"
$currentDirectory = [System.IO.Path]::GetDirectoryName($MyInvocation.InvocationName)
$destinationZippedFilePath = $currentDirectory + "\" + $WebappPackageName
$destinationBackupPath = $currentDirectory + "\" + $DBPackageName
$webapppkgupload = $currentDirectory + "\Upload-WebAppDeployPackage.ps1"
. $webapppkgupload

#Make parameters to be passed to the template SECURE
$_artifactsLocationSasTokenSECURE = $_artifactsLocationSasToken | ConvertTo-SecureString -AsPlainText -Force

#Fill in optional parameters object
$OptionalParameters["sqlServerName"] = $sqlServerName
$OptionalParameters["sqlServerDbName"] = $sqlServerDbName
$OptionalParameters["WebAppDeployPackageStorageName"] = $WebappDeployStorageAccountName
$OptionalParameters["WebAppDeployPackageContainerName"] = $WebappDeployStorageContainerName
$OptionalParameters["WebAppDeployPackageFileName"] = $WebappPackageName
$OptionalParameters["DBDeployPackageFileName"] = $DBPackageName
$OptionalParameters["_artifactsLocationSasToken"] = $_artifactsLocationSasTokenSECURE

#Check if DB already exists
$importDBJsonOption = $true

$sqlDatabse = Get-AzureRmSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $sqlServerName.ToLowerInvariant() -DatabaseName $sqlServerDbName -ErrorAction SilentlyContinue
if($sqlDatabse) {
    $importDBJsonOption = $false
}

$OptionalParameters["importDBJsonOption"] = $importDBJsonOption


if ($ValidateOnly) {
    $ErrorMessages = Format-ValidationOutput (Test-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                                                                                  -TemplateFile $TemplateFile `
                                                                                  -TemplateParameterFile $TemplateParametersFile `
																				  -WebAppDeployPackageStorageName $WebappDeployStorageAccountName `
																				  -WebAppDeployPackageContainerName $WebappDeployStorageContainerName `
																				  -WebAppDeployPackageFileName $WebappPackageName `
																				  -DBDeployPackageFileName $DBPackageName `
                                                                                  -importDBJsonOption $importDBJsonOption `
                                                                                  -sqlServerName $sqlServerName `
                                                                                  -sqlServerDbName $sqlServerDbName `
																				  -_artifactsLocationSasToken $_artifactsLocationSasTokenSECURE)
    if ($ErrorMessages) {
        Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
    }
    else {
        Write-Output '', 'Template is valid.'
    }
}
else {
    New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                       -ResourceGroupName $ResourceGroupName `
                                       -TemplateFile $TemplateFile `
                                       -TemplateParameterFile $TemplateParametersFile `
                                       @OptionalParameters `
                                       -Force -Verbose `
                                       -ErrorVariable ErrorMessages
    if ($ErrorMessages) {
        Write-Output '', 'Template deployment returned the following errors:', @(@($ErrorMessages) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
    }
	else{

		##### Delete temporal storage account #####

		Remove-AzureRmStorageAccount -Name $WebappDeployStorageAccountName -ResourceGroupName $ResourceGroupName -Force

		##### Delete temporal storage account #####
	}
}