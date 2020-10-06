param (
    $OctopusURL,
    $OctopusApiKey,
    $OctopusSpaceName,
    $OctopusWorkerPoolName,
    $AzureTenantId,
    $AzureSubscriptionName,
    $AzureNetworkResourceGroupName,
    $AzureNetworkResourceGroupLocation,
    $AzureNetworkName,
    $AzureNetworkLocation,
    $AzureNetworkSubnetName,
    $AzureNetworkAddressSpace,
    $AzureNetworkSubnetAddressPrefix,
    $AzureSQLResourceGroupName,
    $AzureSQLServerName
)

$ErrorActionPreference = "Stop"

function Write-OctopusSuccess
{
    param($message)

    Write-Host $message -ForegroundColor Green
}

function Write-OctopusWarning
{
    param($message)

    Write-Host $message -ForegroundColor Red
}

function Write-OctopusVerbose
{
    param($message)

    Write-Host $message -ForegroundColor White
}

function Get-ParameterValue
{
    param
    (
        $originalParameterValue,
        $parameterName
    )

    if ($null -ne $originalParameterValue -and [string]::IsNullOrWhiteSpace($originalParameterValue) -eq $false)
    {
        return $originalParameterValue
    }

    return Read-Host -Prompt "Please enter a value for $parameterName"
}

function Get-ParameterValueWithDefault
{
    param
    (
        $originalParameterValue,
        $parameterName,
        $defaultValue
    )

    $returnValue = Get-ParameterValue -originalParameterValue $originalParameterValue -parameterName $parameterName

    if ([string]::IsNullOrWhiteSpace($returnValue) -eq $true)
    {
        return $defaultValue
    }

    return $returnValue
}

function Invoke-OctopusApi
{
    param
    (
        $EndPoint,
        $SpaceId,
        $OctopusURL,
        $apiKey,
        $method,
        $item
    )

    $url = "$OctopusUrl/api/$spaceId/$EndPoint"
    if ([string]::IsNullOrWhiteSpace($SpaceId))
    {
        $url = "$OctopusUrl/api/$EndPoint"
    } 
    
    if ($null -eq $EndPoint -and $null -eq $SpaceId)
    {
        $url = "$OctopusUrl/api"
    }

    if ($null -eq $item)
    {           
        Write-OctopusVerbose "Invoking GET $url" 
        return Invoke-RestMethod -Method $method -Uri $url -Headers @{"X-Octopus-ApiKey" = "$ApiKey" } -ContentType 'application/json; charset=utf-8'
    }

    $body = $item | ConvertTo-Json -Depth 10        

    Write-OctopusVerbose "Invoking $method $url"
    return Invoke-RestMethod -Method $method -Uri $url -Headers @{"X-Octopus-ApiKey" = "$ApiKey" } -Body $body -ContentType 'application/json; charset=utf-8'
}

function Get-OctopusItemByName
{
    param (
        $ItemList,
        $ItemName
        )    

    return ($ItemList | Where-Object {$_.Name -eq $ItemName})
}

function Import-AzurePowerShellModules
{
    if (Get-Module -Name Az -ListAvailable)
    {    
        Write-OctopusVerbose "Azure Az Module found."
    }
    else
    {
        Write-OctopusVerbose "Azure Az Modules not found.  Installing the Azure Az PowerShell Modules.  You might be prompted that PSGallery is untrusted.  If you select Yes your screen might freeze for a second while the modules download process is started."
        Install-Module -Name Az -AllowClobber -Scope CurrentUser
    }

    Write-OctopusVerbose "Loading the Azure Az Module.  This may cause the screen to freeze while loading the module."
    Import-Module -Name Az
}

function Get-OctopusSpaceInformation
{
    param (
        $OctopusApiKey,
        $OctopusUrl,
        $OctopusSpaceName
    )

    Write-OctopusVerbose "Testing the API crendentials of the credentials supplied by pulling the space information"
    $spaceResults = Invoke-OctopusApi -EndPoint "spaces?skip=0&take=100000" -SpaceId $null -OctopusURL $OctopusURL -apiKey $OctopusApiKey -method "Get" -item $null
    $spaceInfo = Get-OctopusItemByName -ItemList $spaceResults.Items -ItemName $OctopusSpaceName

    if ($null -ne $spaceInfo -and $null -ne $spaceInfo.Id)
    {
        Write-OctopusSuccess "Successfully connected to the Octopus Deploy instance provided.  The space id for $OctopusSpaceName is $($spaceInfo.Id)"
        return $spaceInfo
    }
    else
    {
        Write-OctopusWarning "Unable to connect to $OctopusUrl.  Please check your credentials and try again."
        exit 1
    }    
}

function Get-UserAnswer
{
    param (
        $TestCondition,
        $ItemName       
    )

    if ($TestCondition)
    {
        Write-OctopusWarning "The $itemName does not exist."
        $answer = Read-Host -Prompt "Would you like to create the $itemName.  Answering n will stop this script.  y/n"
        if ($answer.ToLower() -ne "y")
        {
            Write-OctopusWarning "You have chosen not to continue.  Stopping script"
            exit
        }
    }
    else {
        Write-OctopusVerbose "The $itemName already exists."
    }

    return $TestCondition
}

Write-OctopusVerbose "This script will do the following:"
Write-OctopusVerbose "    1) In Azure: spin up an ACS container and to use an Octopus Worker (https://octopus.com/docs/infrastructure/workers)"
Write-OctopusVerbose "    2) In Octopus Deploy: Ensure the worker pool exists and if it does not, then creates it."

Write-OctopusVerbose "For this to work you will need to have the following installed.  If it is not installed, then this script will it install it for you from the PowerShell Gallery."
Write-OctopusVerbose "    1)  Azure Az Powershell Modules"

$answer = Read-Host -Prompt "Do you wish to continue? y/n"
if ($answer.ToLower() -ne "y")
{
    Write-OctopusWarning "You have chosen not to continue.  Stopping script"
    Exit
}

Import-AzurePowerShellModules

$OctopusURL = Get-ParameterValue -originalParameterValue $OctopusURL -parameterName "the URL of your Octopus Deploy Instance, example: https://samples.octopus.com.  This is to register the container with your instance."
$OctopusApiKey = Get-ParameterValue -originalParameterValue $OctopusApiKey -parameterName "the API Key of your Octopus Deploy User.  See https://octopus.com/docs/octopus-rest-api/how-to-create-an-api-key for a guide on how to create one.  This is to register the container with your instance"
$OctopusWorkerPoolName = Get-ParameterValueWithDefault -originalParameterValue $OctopusWorkerPoolName -parameterName "the name of the Octopus Deploy Worker Pool.  Do not use 'Default Worker Pool' as that should be left alone and never modified.  If left empty it will default to 'Azure Container Worker Pool'" -defaultValue "Azure Container Worker Pool"
$OctopusSpaceName = Get-ParameterValueWithDefault -originalParameterValue $OctopusSpaceName -parameterName "the name of the space in Octopus Deploy.  This is to register the container with your instance. If left empty it will default to 'Default'" -defaultValue "Default"

$spaceInfo = Get-OctopusSpaceInformation -OctopusApiKey $OctopusApiKey -OctopusUrl $OctopusURL -OctopusSpaceName $OctopusSpaceName
$workerPoolList = Invoke-OctopusApi -EndPoint "workerpools?skip=0&take=100000" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -method "GET" -OctopusUrl $OctopusUrl -item $null
$workerPool = Get-OctopusItemByName -ItemList $workerPoolList.Items -ItemName $OctopusWorkerPoolName
$createWorkerPool = Get-UserAnswer -ItemName "worker pool '$OctopusWorkerPoolName'" -TestCondition $($null -eq $workerPool)

if ($createWorkerPool)
{
    Write-OctopusVerbose "Creating worker pool in Octopus Deploy."
    $worker = @{
        Name = $OctopusWorkerPoolName
        IsDefault = $false
        CanAddWorkers = $true
        SpaceId = $SpaceInfo.Id
        WorkerPoolType = "StaticWorkerPool"
    }

    $workerResource = Invoke-OctopusApi -EndPoint "workerpools" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -method "POST" -OctopusUrl $OctopusUrl -item $worker
    Write-OctopusSuccess "The worker pool $OctopusWorkerPoolName was successfully created.  The new id of the workerpool is $($workerResource.Id)"
}

Write-OctopusVerbose "Octopus Deploy is all ready to go.  Moving onto Azure."
$AzureTenantId = Get-ParameterValue -originalParameterValue $AzureTenantId -parameterName "the ID (GUID) of the Azure tenant you wish to connect to.  See https://microsoft.github.io/AzureTipsAndTricks/blog/tip153.html on how to get that id"
$AzureSubscriptionName = Get-ParameterValue -originalParameterValue $AzureSubscriptionName -parameterName "the name of the subscription you wish to connect Octopus Deploy to"

Write-OctopusVerbose "Logging into Azure"
Connect-AzAccount -Tenant $AzureTenantId -Subscription $AzureSubscriptionName  

$AzureNetworkName = Get-ParameterValue -originalParameterValue $AzureNetworkName -parameterName "the name of the virtual network to attach the container to"
$AzureNetworkResourceGroupName = Get-ParameterValue -originalParameterValue $AzureNetworkResourceGroupName -parameterName "the name of the resource group the virtual network should live in"

try{
    $networkResourceGroup = Get-AzResourceGroup -Name $AzureNetworkResourceGroupName
    $networkResourceGroup | Format-Table
}
catch
{
    $createNetworkResourceGroup = Get-UserAnswer -ItemName "Azure Resource Group '$AzureNetworkResourceGroupName'" -TestCondition $($null -eq $networkResourceGroup)
    if ($createNetworkResourceGroup)
    {
        Write-OctopusVerbose "Creating the resource group $AzureNetworkResourceGroupName for the virtual network.  First we need to know where this resource group will live.  Listing out locations."
        Get-AzLocation |Format-Table
        $AzureNetworkResourceGroupLocation = Get-ParameterValue -originalParameterValue $AzureNetworkResourceGroupLocation -parameterName "the location of the resource group for the virtual network.  Examples include centralus, northcentralus, australiaeast, etc.  See above for full list."
    
        New-AzResourceGroup -Name $AzureNetworkResourceGroupName -Location $AzureNetworkResourceGroupLocation
    }    
}

try{
    $existingNetwork = Get-AzVirtualNetwork -Name $AzureNetworkName -ResourceGroupName $AzureNetworkResourceGroupName
    $existingNetwork | Format-Table
}
catch
{
    $createVirtualNetwork = Get-UserAnswer -ItemName "Azure Virtual Network '$AzureNetworkName' in the Resource Group '$AzureNetworkResourceGroupName'" -TestCondition $($null -eq $networkResourceGroup)
    if ($createNetworkResourceGroup)
    {
        Write-OctopusVerbose "Creating the virtual network '$AzureNetworkName'"        
        $AzureNetworkAddressSpace = Get-ParameterValue -originalParameterValue $AzureNetworkAddressSpace -parameterName "the IP address prefix.  Typically it is 172.19.0.0/16 or 10.0.0.0/16 or 192.168.0.0/16."
    
        $LocationToUse = $AzureNetworkResourceGroupLocation

        if ($null -eq $LocationToUse)
        {
            Write-OctopusVerbose "Now we need to know where this virtual network will live.  Listing out all the locations."
            Get-AzLocation |Format-Table
            $AzureNetworkLocation = Get-ParameterValue -originalParameterValue $AzureNetworkLocation -parameterName "the location of the virtual network.  Examples include centralus, northcentralus, australiaeast, etc.  See above for full list."

            $LocationToUse = $AzureNetworkLocation
        }
        
        New-AzVirtualNetwork -Name $AzureNetworkName -Location $LocationToUse -ResourceGroupName $AzureNetworkResourceGroupName -AddressPrefix $AzureNetworkAddressSpace
    }    
}

$existingNetwork = Get-AzVirtualNetwork -Name $AzureNetworkName -ResourceGroupName $AzureNetworkResourceGroupName
$existingSubnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $existingNetwork
$existingSubnets | Format-Table

foreach ($subnet in $existingSubnets)
{
    Write-OctopusVerbose $subnet.Name
    foreach ($delegation in $subnet.Delegations)
    {
        Write-Host $delegation.ServiceName
    }    
}