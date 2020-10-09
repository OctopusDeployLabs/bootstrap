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
    $AzureSQLServerName,
    $AzureServicePrincpalId,
    $AzureServicePrincpalSecretKey,
    $AzureContainerResourceGroupName,
    $AzureContainerGroupName,
    $DockerImageToUse,
    $DockerCPUCount,
    $DockerMemoryInGB
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

function Connect-ToAzureAccount
{
    param
    (
        $AzureTenantId,
        $AzureSubscriptionName,
        $AzureServicePrincpalId,
        $AzureServicePrincpalSecretKey
    )

    if ([string]::IsNullOrWhiteSpace($AzureServicePrincpalId) -eq $false)
    {
        Write-OctopusVerbose "Logging into Azure using the supplied service principal"        
        $securePassword = ConvertTo-SecureString $AzureServicePrincpalSecretKey -AsPlainText -Force
        $azureCredential = New-Object System.Management.Automation.PSCredential ($AzureServicePrincpalId, $securePassword)
        Connect-AzAccount -Tenant $AzureTenantId -Subscription $AzureSubscriptionName -ServicePrincipal -Credential $azureCredential 

    }
    else 
    {
        Write-OctopusVerbose "Logging into Azure"
        Connect-AzAccount -Tenant $AzureTenantId -Subscription $AzureSubscriptionName     
    }
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
        $AzureNetworkSubnetAddressPrefix,
        $AzureNetworkLocation
    )

    Write-OctopusVerbose "Pulling all the subnets of the virtual network"
    $existingSubnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $existingNetwork
    $subnetsThatQualifyForAzureServiceContainer = @()
    $subnetsAlreadyRegisteredForContainerGroups = @()
    $AzureNetworkSubnetName = Get-ParameterValue -originalParameterValue $AzureNetworkSubnetName -parameterName "the name of the subnet to connect the Azure Service Container to"
    $subnetToUpdate = $existingSubnets | Where-Object {$_.Name -eq $AzureNetworkSubnetName}    
    
    if ($null -eq $subnetToUpdate)
    {
        Write-Host "The subnet $AzureNetworkSubnetName was not found."

        foreach ($subnet in $existingSubnets)
        {               
            $isRegisteredToContainerGroups = $false
            foreach ($delegation in $subnet.Delegations)
            {
                if ($delegation.ServiceName -eq "Microsoft.ContainerInstance/containerGroups")
                {
                    $subnetsAlreadyRegisteredForContainerGroups += $subnet.Name                    
                    $isRegisteredToContainerGroups = $true
                    
                    break
                }
            }            

            if ($isRegisteredToContainerGroups -eq $false -and $subnet.IpConfigurations.Count -eq 0)
            {
                $subnetsThatQualifyForAzureServiceContainer += $subnet.Name
            }
        }

        
        $subnetNameToUse = $null
        if ($subnetsAlreadyRegisteredForContainerGroups.Length -gt 0)
        {
            $subnetNameToUse = Read-Host "The following subnets already are registered for Azure Container Services, please enter the name of the one you want to pick.  If you leave this blank you will be prompted to create a new subnet. Existing subnets to pick: $subnetsAlreadyRegisteredForContainerGroups"            
        }
        elseif ($subnetsThatQualifyForAzureServiceContainer.Length -gt 0)
        {
            $subnetNameToUse = Read-Host "You don't have any subnets that already are registered for Azure Container Services, but these do not have any IP addresses associated with them.  Please enter the name of the one you want to pick.  If you leave this blank you will be prompted to create a new subnet.  Existing subnets to pick: $subnetsThatQualifyForAzureServiceContainer"
        }

        if ([string]::IsNullOrWhiteSpace($subnetNameToUse) -eq $false)
        {
            $subnetToUpdate = $existingSubnets | Where-Object {$_.Name -eq $subnetNameToUse}
        }
    }

    if ($null -ne $subnetToUpdate)
    {
        $containerRegistration = @($subnetToUpdate.Delegations | Where-Object {$_.ServiceName -eq "Microsoft.ContainerInstance/containerGroups"})
        $serviceRegistration = @($subnetToUpdate.ServiceEndpoints | Where-Object {$_.Service -eq "Microsoft.Sql" })

        if ($containerRegistration.Count -gt 0 -and $serviceRegistration.Count -gt 0)
        {
            Write-OctopusSuccess "Found the subnet specified.  It is already configured to host Azure Containers and connect to Azure SQL.  Moving on."
            return $subnetToUpdate.Name
        }

        Write-OctopusVerbose "The subnet specified exists.  Checking to see if needs to be updated"
        if ($containerRegistration.Count -eq 0)
        {
            Write-OctopusVerbose "The subnet is not registered to allow Azure Continers to connect to it.  Adding that delegation."
            $delegationToAdd = New-AzDelegation -ServiceName "Microsoft.ContainerInstance/containerGroups" -Name "ACIDelegationService"
            $subnetToUpdate.Delegations.Add($delegationToAdd)
        }

        if ($serviceRegistration.Count -eq 0)
        {
            Write-OctopusVerbose "The subnet is not configured to connect to Azure SQL via a service endpoint.  Adding that service endpoint."
            $sqlDelegation = New-AzServiceEndpointPolicyDefinition -Name "$($subnetToUpdate.Name)-AzureSQL" -Service "Microsoft.SQL"
            
            # Service Endpoint Policy
            $sep = New-AzServiceEndpointPolicy -ResourceGroupName $rgName -Name "$($subnetToUpdate.Name)-AzureSQL" -Location $AzureNetworkLocation -ServiceEndpointPolicyDefinition $sqlDelegation
            
            $subnetToUpdate.ServiceEndpoints.Add($sep)
        }
                    
        Write-OctopusVerbose "Updating the subnet now."
        Set-AzVirtualNetwork -VirtualNetwork $existingNetwork

        return $subnetToUpdate.Name
    }

    Write-OctopusVerbose "Okay, going to create a new subnet because the script couldn't find one that qualifies."
    $continueWithScript = Read-Host "Do you wish to continue and create a new subnet? Answering n will stop the script y/n"
    if ($continueWithScript.ToLower() -ne "y")
    {
        Write-OctopusVerbose "Okay, stopping script."
        exit
    }

    $AzureNetworkSubnetAddressPrefix = Get-ParameterValue -originalParameterValue $AzureNetworkSubnetAddressPrefix -parameterName "the address prefix for the new subnet.  Must be a viable subnet in $($existingNetwork.AddressSpaceText)"

    $delegation = New-AzDelegation -Name "$AzureNetworkSubnetName-ACIDelegationService" -ServiceName "Microsoft.ContainerInstance/containerGroups"
    $newSubnet = New-AzVirtualNetworkSubnetConfig -Name $AzureNetworkSubnetName -AddressPrefix $AzureNetworkSubnetAddressPrefix -Delegation @($delegation) -ServiceEndpoint "Microsoft.Sql"
    $existingNetwork.Subnets.Add($newSubnet)
    Set-AzVirtualNetwork -VirtualNetwork $existingNetwork

    return $AzureNetworkSubnetName
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

Connect-ToAzureAccount -AzureTenantId $AzureTenantId -AzureSubscriptionName $AzureSubscriptionName -AzureServicePrincpalId $AzureServicePrincpalId -AzureServicePrincpalSecretKey $AzureServicePrincpalSecretKey

$AzureNetworkName = Get-ParameterValue -originalParameterValue $AzureNetworkName -parameterName "the name of the virtual network to attach the container to"
$AzureNetworkResourceGroupName = Get-ParameterValue -originalParameterValue $AzureNetworkResourceGroupName -parameterName "the name of the resource group the virtual network should live in"
$LocationToUse = $AzureNetworkResourceGroupLocation
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
    
        $LocationToUse = $AzureNetworkResourceGroupLocation
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
$subnetToUse = Set-AzureSubnet -existingNetwork $existingNetwork -AzureNetworkSubnetName $AzureNetworkSubnetName -AzureNetworkSubnetAddressPrefix $AzureNetworkSubnetAddressPrefix -AzureNetworkLocation $AzureNetworkLocation

$existingSubnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $existingNetwork
$azureSubnet = $existingSubnets | Where-Object {$_.Name -eq $subnetToUse}

Write-OctopusVerbose "Now checking to see if the Azure SQL Server Firewall allows connections from $subnetToUse"
$AzureSQLResourceGroupName = Get-ParameterValue -originalParameterValue $AzureSQLResourceGroupName -parameterName "the resource group your Azure SQL Server instance is assigned to"
$AzureSQLServerName = Get-ParameterValue -originalParameterValue $AzureSQLServerName -parameterName "the name of your Azure SQL Server"

Write-OctopusVerbose "Getting the virtual network rules for the Azure SQL Server $AzureSQLServerName in the resource group $AzureSQLResourceGroupName"
$virtualNetworkRuleList = Get-AzSqlServerVirtualNetworkRule -ResourceGroupName $AzureSQLResourceGroupName -ServerName $AzureSQLServerName

$alreadyConnected = $false
foreach ($virtualNetworkRule in $virtualNetworkRuleList)
{    
    if ($azureSubnet.Id -eq $virtualNetworkRule.VirtualNetworkSubnetId)
    {
        $alreadyConnected = $true
        Write-OctopusSuccess "The virtual network subnet is already connected to the Azure SQL Server Instance"
        break
    }
}

if ($alreadyConnected -eq $false)
{
    Write-OctopusVerbose "Adding the subnet to the Azure SQL Server Firewall"
    New-AzSqlServerVirtualNetworkRule -ResourceGroupName $AzureSQLResourceGroupName -ServerName $AzureSQLServerName -VirtualNetworkRuleName "$AzureNetworkName-$subnetToUse" -VirtualNetworkSubnetId $azureSubnet.Id
    Write-OctopusSuccess "Successfully added $subnetToUse to the firewall for Azure SQL Server $AzureSQLServerName in the resource group $AzureSQLResourceGroupName"
}

Write-OctopusVerbose "Okay...finally.  The worker pools exists in Octopus Deploy, the subnet exists and can connect to Azure SQL.  Time to create the docker container."

$AzureContainerResourceGroupName = Get-ParameterValue -originalParameterValue $AzureContainerResourceGroupName -parameterName "the resource group the Azure Container will live in"

try{
    Write-OctopusVerbose "Checking to see if the container resource group $AzureContainerResourceGroupName exists"
    $containerResourceGroup = Get-AzResourceGroup -Name $AzureContainerResourceGroupName    
    Write-OctopusVerbose "$AzureContainerResourceGroupName exists moving on"
}
catch
{
    $createContainerResourceGroup = Get-UserAnswer -ItemName "Azure Resource Group '$AzureContainerResourceGroupName'" -TestCondition $($null -eq $containerResourceGroup)
    if ($createContainerResourceGroup)
    {
        Write-OctopusVerbose "Creating the resource group $AzureContainerResourceGroupName Azure Container."
        
        $LocationToUse = $AzureNetworkResourceGroupLocation

        if ($null -eq $LocationToUse)
        {
            Write-OctopusVerbose "Now we need to know where this virtual network will live.  Listing out all the locations."
            Get-AzLocation | Format-Table
            $AzureNetworkLocation = Get-ParameterValue -originalParameterValue $AzureNetworkLocation -parameterName "the location of the container resource group.  Examples include centralus, northcentralus, australiaeast, etc.  See above for full list."

            $LocationToUse = $AzureNetworkLocation
        }                
    
        New-AzResourceGroup -Name $AzureContainerResourceGroupName -Location $LocationToUse
    }    
}

$AzureContainerGroupName = Get-ParameterValue -originalParameterValue $AzureContainerGroupName -parameterName "the name of the Azure Container Group."

$existingContainers = Get-AzContainerGroup -ResourceGroupName $AzureContainerResourceGroupName

foreach ($container in $existingContainers)
{
    if ($container.Name -eq $AzureContainerGroupName)
    {        
        Write-OctopusVerbose "The container already exists, deleting it so it can be updated."
        Remove-AzContainerGroup -ResourceGroupName $AzureContainerResourceGroupName -Name $AzureContainerGroupName
    }
}

$DockerImageToUse = Get-ParameterValueWithDefault -originalParameterValue $DockerImageToUse -parameterName "docker hub image to use. The default is octopuslabs/tentacle-worker.  Leave blank for default" -defaultValue "octopuslabs/tentacle-worker"
$DockerCPUCount = Get-ParameterValueWithDefault -originalParameterValue $DockerCPUCount -parameterName "the number of CPUs to associate to the container.  Default is 1.  Leave blank for default" -defaultValue "1"
$DockerMemoryInGB = Get-ParameterValueWithDefault -originalParameterValue $DockerMemoryInGB -parameterName "the amount of memory (in GB) to associate to the container.  Default is 1.5.  Leave blank for default" -defaultValue "1.5"

$environmentVariables = @{
    SERVER_URL="$OctopusURL"
    SERVER_API_KEY="$OctopusApiKey"
    REGISTRATION_NAME="$AzureContainerGroupName" 
    TARGET_WORKER_POOL="$OctopusWorkerPoolName" 
    SPACE="$OctopusSpaceName" 
    ACCEPT_EULA="Y"
}

$containerNicConfigIpConfig = New-AzContainerNicConfigIpConfig -Name "$AzureContainerGroupName-ip" -subnet $azureSubnet -SubnetId $azureSubnet.Id
$containerNicConfig = New-AzContainerNicConfig -Name "$AzureContainerGroupName-nic" -IpConfiguration $containerNicConfigIpConfig
$networkProfile = New-AzNetworkProfile -Name "$AzureContainerGroupName-profile" -Location $LocationToUse -ResourceGroupName $AzureContainerResourceGroupName -ContainerNetworkInterfaceConfiguration $containerNicConfig
Write-OctopusVerbose "Creating the Azure Container.  This might freeze the screen while everything is setup in Azure."
$container = New-AzContainerGroup -ResourceGroupName $AzureContainerResourceGroupName -Name $AzureContainerGroupName -Location $LocationToUse -Image $DockerImageToUse -OsType "Linux" -Cpu $DockerCPUCount -MemoryInGB $DockerMemoryInGB -EnvironmentVariable $environmentVariables -NetworkProfile $networkProfile