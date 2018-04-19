$storageAcc = Get-AzureRmStorageAccount -Name $WebappDeployStorageAccountName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
while($storageAcc)
{
  Write-Host "Storage account with '$WebappDeployStorageAccountName' name already exists. You need to create a different one. Please, enter a new name to create a new one";
  $WebappDeployStorageAccountName = Read-Host "WebappDeployStorageAccountName";
  $storageAcc = Get-AzureRmStorageAccount -Name $WebappDeployStorageAccountName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
}
Write-Host "Creating storage account '$WebappDeployStorageAccountName' in location '$ResourceGroupLocation'";
New-AzureRmStorageAccount -Location $ResourceGroupLocation -Name $WebappDeployStorageAccountName -ResourceGroupName $ResourceGroupName -SkuName $WebappDeployStorageAccountGeoLocation -WarningAction SilentlyContinue
$storageAcc = Get-AzureRmStorageAccount -Name $WebappDeployStorageAccountName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

$storageKey = (Get-AzureRmStorageAccountKey -Name $WebappDeployStorageAccountName -ResourceGroupName $ResourceGroupName)[0].Value

### Create the source storage account context ### 
$storageContext = New-AzureStorageContext  –StorageAccountName $WebappDeployStorageAccountName `
                                        -StorageAccountKey $storageKey


New-AzureStorageContainer -Name $WebappDeployStorageContainerName -Context $storageContext
$_artifactsLocationSasToken = New-AzureStorageContainerSASToken -Name $WebappDeployStorageContainerName -Permission rwdl -Context $storageContext -ExpiryTime (Get-Date).AddMonths(1)


#Upload packages
Set-AzureStorageBlobContent -File $destinationZippedFilePath -Blob $WebappPackageName -Container $WebappDeployStorageContainerName -Context $storageContext -Force -ErrorAction Stop
Set-AzureStorageBlobContent -File $destinationBackupPath -Blob $DBPackageName -Container $WebappDeployStorageContainerName -Context $storageContext -Force -ErrorAction Stop