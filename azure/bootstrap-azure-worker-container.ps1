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

function Set-AzureSubnet
{
    param (
        $existingNetwork,
        $AzureNetworkSubnetName,
        $AzureNetworkSubnetAddressPrefix
    )

    Write-OctopusVerbose "Pulling all the subnets of the virtual network"
    $existingSubnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $existingNetwork
    $subnetsThatQualifyForAzureServiceContainer = @()
    $subnetsAlreadyRegisteredForContainerGroups = @()
    $AzureNetworkSubnetName = Get-ParameterValue -originalParameterValue $AzureNetworkSubnetName -parameterName "the name of the subnet to connect the Azure Service Container to"
    $desiredSubnetExists = $false
    $desiredSubnetRegisteredForAzureServiceContainerGroups = $false
    $desiredSubnetHasIpsAllocated = $false

    foreach ($subnet in $existingSubnets)
    {       
        $isRegisteredToContainerGroups = $false
        if ($subnet.Name -eq $AzureNetworkSubnetName)
        {
            Write-OctopusVerbose "Found the subnet $AzureNetworkSubnetName"
            $desiredSubnetExists = $true
        }

        foreach ($delegation in $subnet.Delegations)
        {
            if ($delegation.ServiceName -eq "Microsoft.ContainerInstance/containerGroups")
            {
                $isRegisteredToContainerGroups = $true

                if ($subnet.Name -eq $AzureNetworkSubnetName)
                {
                    $desiredSubnetRegisteredForAzureServiceContainerGroups = $true
                }
                else
                {
                    $subnetsAlreadyRegisteredForContainerGroups += $subnet.Name    
                }
                
                break
            }
        }    

        $desiredSubnetHasIpsAllocated = $($subnet.IpConfigurations.Count -eq 0)

        if ($isRegisteredToContainerGroups -eq $false -and $subnet.IpConfigurations.Count -eq 0)
        {
            $subnetsThatQualifyForAzureServiceContainer += $subnet.Name
        }
    }

    if ($desiredSubnetExists -eq $true -and $desiredSubnetRegisteredForAzureServiceContainerGroups -eq $true)
    {
        Write-OctopusVerbose "Found the subnet specified.  It is already configured to host Azure Containers.  Moving on."
        return $AzureNetworkSubnetName
    }
    elseif ($desiredSubnetExists -eq $true -and $desiredSubnetRegisteredForAzureServiceContainerGroups -eq $false -and $desiredSubnetHasIpsAllocated -eq $false)
    {
        $updateExistingSubnet = Read-Host -Prompt "The subnet specified exists, but it is not configured to host Azure Containers.  It doesn't have anything connected to it.  Do you wish to update it to host Azure Containers?  WARNING: this means this subnet can only have Azure Containers connect to it!  Proceed with update? y/n"
        if ($updateExistingSubnet.ToLower() -eq "y")
        {
            New-AzureSubnetDelegation -existingNetwork $existingNetwork -subnetName $AzureNetworkSubnetName
            return $AzureNetworkSubnetName
        }    
    }
    elseif ($desiredSubnetExists -eq $true -and $desiredSubnetRegisteredForAzureServiceContainerGroups -eq $false -and $desiredSubnetHasIpsAllocated -eq $true)
    {
        $continueWithScript = Read-Host -Prompt "The subnet specified exists, but it not configured to host Azure Containers and it cannot be updated to do so since it already has IPs allocated.  Do you wish to continue?  The script will prompt you to update an existing subnet, pick a subnet which is already configured, or create a new one.  Selecting n will stop the script.  y/n"
        if ($continueWithScript.ToLower() -ne "y")
        {
            Write-OctopusWarning "You elected to not continue.  Stopping script."
            exit
        }
    }

    if ($subnetsAlreadyRegisteredForContainerGroups.Length -gt 0)
    {
        Write-OctopusVerbose "The subnet specified couldn't be found or it isn't configured properly.  The following subnets are configured to allow Azure Containers to connect to them."
        Write-OctopusVerbose $subnetsAlreadyRegisteredForContainerGroups
        $subnetName = Get-ParameterValue -originalParameterValue $null -parameterName "the name of the subnet from that list to connect the Azure Service Container to.  Leaving blank will prompt you to create or update an existing subnet."

        if ([string]::IsNullOrWhiteSpace($subnetName) -eq $false)
        {
            Write-OctopusVerbose "Okay, will use $AzureNetworkSubnetName going forward."
            return $subnetName    
        }
    }

    if ($subnetsThatQualifyForAzureServiceContainer.Length -gt 0)
    {
        Write-OctopusVerbose "The subnet specified couldn't be found or it isn't configured properly.  The following subnets are NOT configured to allow Azure Containers to connect to them but have no IP Addresses allocated to them."
        Write-OctopusVerbose $subnetsAlreadyRegisteredForContainerGroups
        $subnetName = Get-ParameterValue -originalParameterValue $null -parameterName "the name of the subnet from that list to connect the Azure Service Container to.  Leaving blank will prompt you to create a new subnet.  Warning! This will update the existing subnet to only allow Azure Containers to connect to it."

        if ([string]::IsNullOrWhiteSpace($subnetName) -eq $false)
        {
            Write-OctopusVerbose "Okay, will first try to update that existing subnet."
            New-AzureSubnetDelegation -existingNetwork $existingNetwork -subnetName $subnetName
            return $subnetName
        }
    }

    Write-OctopusVerbose "Couldn't find a subnet to attach the Azure Service Container to AND all existing subnets are being used."
    $continueWithScript = Read-Host "Do you wish to continue and create a new subnet? Answering n will stop the script y/n"
    if ($continueWithScript.ToLower() -ne "y")
    {
        Write-OctopusVerbose "Okay, stopping script."
        exit
    }

    $subnetName = Get-ParameterValue -originalParameterValue $null -parameterName "the name of the NEW subnet from connect the Azure Service Container to"
    $AzureNetworkSubnetAddressPrefix = Get-ParameterValue -originalParameterValue $AzureNetworkSubnetAddressPrefix -parameterName "the address prefix for the new subnet.  Must be a viable subnet in $($existingNetwork.AddressSpaceText)"

    $delegation = New-AzDelegation -Name "ACIDelegationService" -ServiceName "Microsoft.ContainerInstance/containerGroups"
    $newSubnet = New-AzVirtualNetworkSubnetConfig -Name $AzureNetworkSubnetName -AddressPrefix $AzureNetworkSubnetAddressPrefix -Delegation = @($delegation)
    $existingNetwork.Subnets.Add($newSubnet)
    Set-AzVirtualNetwork $existingNetwork

    return $subnetName
}

function New-AzureSubnetDelegation
{
    param (
        $existingNetwork,
        $subnetName
    )

    $delegationToAdd = New-AzDelegation -ServiceName "Microsoft.ContainerInstance/containerGroups" -Name "ACIDelegationService"
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $existingNetwork
    $subnet.Delegations.Add($delegationToAdd)
    Set-AzVirtualNetwork $existingNetwork
}

Write-OctopusVerbose "This script will create an Octopus Deploy Worker as an Azure Service Container.  It will do that by doing the following:"
Write-OctopusVerbose "    1) Octopus Deploy: Verify worker pool (https://octopus.com/docs/infrastructure/workers) exists.  If not it will create it."
Write-OctopusVerbose "    2) Azure: Verify if there is virtual network to connect the container to.  If not it will create one."
Write-OctopusVerbose "    3) Azure: Verify if there is a subnet dedicated to Azure Service Contianers on that virtual network.  If not it will create one."
Write-OctopusVerbose "    4) Azure: Verify if there is a an Azure SQL Server running.  If not, it will create one."
Write-OctopusVerbose "    5) Azure: Verify the Azure SQL Server allows connections from the subnet created from an earlier step.  If not, it will update the firewall."

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
    Write-OctopusVerbose "Checking to see if the network resource group $AzureNetworkResourceGroupName exists"
    $networkResourceGroup = Get-AzResourceGroup -Name $AzureNetworkResourceGroupName    
    Write-OctopusVerbose "$AzureNetworkResourceGroupName exists moving on"
}
catch
{
    $createNetworkResourceGroup = Get-UserAnswer -ItemName "Azure Resource Group '$AzureNetworkResourceGroupName'" -TestCondition $($null -eq $networkResourceGroup)
    if ($createNetworkResourceGroup)
    {
        Write-OctopusVerbose "Creating the resource group $AzureNetworkResourceGroupName for the virtual network.  First we need to know where this resource group will live.  Listing out locations."
        Get-AzLocation | Format-Table
        $AzureNetworkResourceGroupLocation = Get-ParameterValue -originalParameterValue $AzureNetworkResourceGroupLocation -parameterName "the location of the resource group for the virtual network.  Examples include centralus, northcentralus, australiaeast, etc.  See above for full list."
    
        New-AzResourceGroup -Name $AzureNetworkResourceGroupName -Location $AzureNetworkResourceGroupLocation
    }    
}

try{
    Write-OctopusVerbose "Checking to see if the virtual network $AzureNetworkName exists"
    $existingNetwork = Get-AzVirtualNetwork -Name $AzureNetworkName -ResourceGroupName $AzureNetworkResourceGroupName    
    Write-OctopusVerbose "$AzureNetworkName exists moving on"
}
catch
{
    $createVirtualNetwork = Get-UserAnswer -ItemName "Azure Virtual Network '$AzureNetworkName' in the Resource Group '$AzureNetworkResourceGroupName'" -TestCondition $($null -eq $networkResourceGroup)
    if ($createVirtualNetwork)
    {
        Write-OctopusVerbose "Creating the virtual network '$AzureNetworkName'"        
        $AzureNetworkAddressSpace = Get-ParameterValue -originalParameterValue $AzureNetworkAddressSpace -parameterName "the IP address prefix.  Typically it is 172.19.0.0/16 or 10.0.0.0/16 or 192.168.0.0/16."
    
        $LocationToUse = $AzureNetworkResourceGroupLocation

        if ($null -eq $LocationToUse)
        {
            Write-OctopusVerbose "Now we need to know where this virtual network will live.  Listing out all the locations."
            Get-AzLocation | Format-Table
            $AzureNetworkLocation = Get-ParameterValue -originalParameterValue $AzureNetworkLocation -parameterName "the location of the virtual network.  Examples include centralus, northcentralus, australiaeast, etc.  See above for full list."

            $LocationToUse = $AzureNetworkLocation
        }
        
        New-AzVirtualNetwork -Name $AzureNetworkName -Location $LocationToUse -ResourceGroupName $AzureNetworkResourceGroupName -AddressPrefix $AzureNetworkAddressSpace
    }    
}

$existingNetwork = Get-AzVirtualNetwork -Name $AzureNetworkName -ResourceGroupName $AzureNetworkResourceGroupName
$subnetToUse = Set-AzureSubnet -existingNetwork $existingNetwork -AzureNetworkSubnetName $AzureNetworkSubnetName -AzureNetworkSubnetAddressPrefix $AzureNetworkSubnetAddressPrefix

$existingSubnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $existingNetwork