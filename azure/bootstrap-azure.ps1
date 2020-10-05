param (
    $OctopusURL,
    $OctopusApiKey,
    $OctopusSpaceName,
    $OctopusAccountName,
    $AzureTenantId,
    $AzureSubscriptionName,
    $AzureServicePrincipalName
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

    Write-OctopusVerbose "Loading the Azure Az Module"
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

function Test-ExistingOctopusAccountWorksWithAzure
{
    param (
        $OctopusApiKey,
        $OctopusUrl,
        $SpaceInfo,
        $ExistingAccount
    )

    Write-OctopusVerbose "The account already exists in Octopus Deploy.  Running a test to ensure it can connect to Azure."
    $testAccountTaskBody = @{
        "Name" = "TestAccount"
        "Description" = "Test Azure account"
        "SpaceId" = $spaceInfo.Id
        "Arguments" = @{
            "AccountId" = $existingAccount.Id
            }
        }

    $checkConnectivityTask = Invoke-OctopusApi -EndPoint "tasks" -SpaceId $null -OctopusURL $OctopusURL -apiKey $OctopusApiKey -method "POST" -item $testAccountTaskBody
    $taskStatusEndPoint = "tasks/$($checkConnectivityTask.Id)"

    $taskState = $checkConnectivityTask.State
    $taskDone = $taskState -eq "Success" -or $taskState -eq "Canceled" -or $taskState -eq "Failed"    

    While ($taskDone -eq $false)
    {
        Write-OctopusVerbose "Checking on the status of the task in 3 seconds"
        Start-Sleep -Seconds 3
        $taskStatus = Invoke-OctopusApi -EndPoint $taskStatusEndPoint -SpaceId $null -OctopusURL $OctopusURL -apiKey $OctopusApiKey -method "GET"        
        $taskState = $taskStatus.State

        Write-Host "The task status is $taskState"
        $taskDone = $taskState -eq "Success" -or $taskState -eq "Canceled" -or $taskState -eq "Failed"

        if ($taskState -eq "Success")
        {
            Write-OctopusSuccess "The Octopus Account can successfully connect to Azure"
            return $true            
        }        
    } 

    return $false
}

function New-OctopusIdList
{
    param (
        $OctopusUrl,
        $OctopusApiKey,
        $spaceInfo,
        $endPoint,
        $itemName
    )

    Write-OctopusVerbose "Checking to see if Octopus Deploy instance has $itemName"
    $allItemsList = Invoke-OctopusApi -EndPoint "$($endPoint)?skip=0&take=100000" -method "Get" -SpaceId $spaceInfo.Id -OctopusURL $OctopusUrl -apiKey $OctopusApiKey
    $IdList = @()

    if ($allItemsList.Items.Count -le 0)
    {
        return $IdList
    }

    $itemFilter = Read-Host -prompt "$itemName records found.  Please enter a comman-separated list of $itemName you'd like to associate the account to.  If left blank the account can be used for all $itemName."        
    
    if ([string]::IsNullOrWhiteSpace($itemFilter) -eq $true)
    {
        return $IdList
    }

    $itemList = $itemFilter -split ","
    foreach ($item in $itemList)
    {
        $foundItem = Get-OctopusItemByName -ItemList $allItemsList.Items -ItemName $item

        if ($null -eq $foundItem)
        {
            Write-OctopusWarning "The $itemName $item was not found in your Octopus Deploy instance."
            $continue = Read-Host -Prompt "Would you like to continue?  If yes, the account will not be tied to $itemName $item.  y/n"
            if ($continue.ToLower() -ne "y")
            {
                exit
            }
        }
        else 
        {
            $IdList += $foundItem.Id    
        }
    }

    return $IdList
}

Write-OctopusVerbose "This script will do the following:"
Write-OctopusVerbose "    1) In Azure: create an Azure Service Principal and associate it with your desired subscription as a contributor.  The password generated is two GUIDs without dashes."
Write-OctopusVerbose "    2) In Octopus Deploy: create an Azure Account using the credentials created in step 1"

Write-OctopusVerbose "For this to work you will need to have the following installed.  If it is not installed, then this script will it install it for you from the PowerShell Gallery."
Write-OctopusVerbose "    1)  Azure Az Powershell Modules"

$answer = Read-Host -Prompt "Do you wish to continue? y/n"
if ($answer.ToLower() -ne "y")
{
    Write-OctopusWarning "You have chosen not to continue.  Stopping script"
    Exit
}

Import-AzurePowerShellModules

$OctopusURL = Get-ParameterValue -originalParameterValue $OctopusURL -parameterName "the URL of your Octopus Deploy Instance, example: https://samples.octopus.com"
$OctopusApiKey = Get-ParameterValue -originalParameterValue $OctopusApiKey -parameterName "the API Key of your Octopus Deploy User.  See https://octopus.com/docs/octopus-rest-api/how-to-create-an-api-key for a guide on how to create one"
$OctopusSpaceName = Get-ParameterValueWithDefault -originalParameterValue $OctopusSpaceName -parameterName "the name of the space in Octopus Deploy.  If left empty it will default to 'Default'" -defaultValue "Default"
$OctopusAccountName = Get-ParameterValueWithDefault -originalParameterValue $OctopusAccountName -parameterName "the name of the account you wish to create in Octopus Deploy.  If left empty it will default to 'Bootstrap Azure Account'" -defaultValue "Bootstrap Azure Account"

$spaceInfo = Get-OctopusSpaceInformation -OctopusApiKey $OctopusApiKey -OctopusUrl $OctopusURL -OctopusSpaceName $OctopusSpaceName

Write-OctopusVerbose "Getting the list of accounts on that space in Octopus Deploy to see if it exists"
$existingOctopusAccounts = Invoke-OctopusApi -EndPoint "accounts?skip=0&take=1000000" -method "GET" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -OctopusURL $OctopusURL
$existingAccount = Get-OctopusItemByName -ItemList $existingOctopusAccounts.Items -ItemName $OctopusAccountName
$OctopusAndAzureServicePrincipalAlreadyExist = $false
$OctopusEnvironmentIdList = @()
$OctopusTenantIdList = @()

if ($null -ne $existingAccount)
{
    $OctopusAndAzureServicePrincipalAlreadyExist = Test-ExistingOctopusAccountWorksWithAzure -OctopusApiKey $OctopusApiKey -OctopusUrl $OctopusURL -SpaceInfo $spaceInfo -ExistingAccount $existingAccount
}
else 
{
    Write-OctopusWarning "The account $OctopusAccountName does not exist.  After creating the Azure Account it will create a new account in Octopus Deploy"
    Write-OctopusVerbose "Octopus accounts can be locked down to specific environments, tenants and tenant tags"
    $OctopusEnvironmentIdList = New-OctopusIdList -OctopusUrl $OctopusURL -OctopusApiKey $OctopusApiKey -spaceInfo $spaceInfo -endPoint "environments" -itemName "environments"
    $OctopusTenantIdList = New-OctopusIdList -OctopusUrl $OctopusURL -OctopusApiKey $OctopusApiKey -spaceInfo $spaceInfo -endPoint "tenants" -itemName "tenants"    
}

if ($OctopusAndAzureServicePrincipalAlreadyExist -eq $true)
{
    $overwriteExisting = Read-Host -Prompt "Octopus Deploy already has a working connection with Azure.  Do you wish to continue?  This will create a new password for the service principal account in Azure and update the account in Octopus Deploy.  y/n"
    If ($overwriteExisting.ToLower() -ne "y")
    {
        Write-OctopusSuccess "Octopus Deploy already has a working connection and you elected to leave it as as is, stopping script."
        exit
    }
}

$AzureTenantId = Get-ParameterValue -originalParameterValue $AzureTenantId -parameterName "the ID (GUID) of the Azure tenant you wish to connect to.  See https://microsoft.github.io/AzureTipsAndTricks/blog/tip153.html on how to get that id"
$AzureSubscriptionName = Get-ParameterValue -originalParameterValue $AzureSubscriptionName -parameterName "the name of the subscription you wish to connect Octopus Deploy to"
$AzureServicePrincipalName = Get-ParameterValue -originalParameterValue $AzureServicePrincipalName -parameterName "the name of the service principal you wish to create in Azure"

Write-OctopusVerbose "Logging into Azure"
Connect-AzAccount -Tenant $AzureTenantId -Subscription $AzureSubscriptionName

Write-OctopusVerbose "Auto-generating new password"
$AzureServicePrincipalEndDays = Get-ParameterValue -originalParameterValue $null -parameterName "the number of days you want the service principal password to be active"
$password = "$(New-Guid)$(New-Guid)" -replace "-", ""
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force

$endDate = (Get-Date).AddDays($AzureServicePrincipalEndDays)

$azureSubscription = Get-AzSubscription -SubscriptionName $AzureSubscriptionName
$azureSubscription | Format-Table

$ExistingApplication = Get-AzADApplication -DisplayName "$AzureServicePrincipalName"
$ExistingApplication | Format-Table

if ($null -eq $ExistingApplication)
{
    Write-OctopusVerbose "The Azure Active Directory Application does not exist, creating Azure Active Directory application"
    $azureAdApplication = New-AzADApplication -DisplayName "$AzureServicePrincipalName" -HomePage "http://octopus.com" -IdentifierUris "http://octopus.com" -Password $securePassword -EndDate $endDate
    $azureAdApplication | Format-Table

    Write-OctopusVerbose "Creating Azure Active Directory service principal"
    $servicePrincipal = New-AzADServicePrincipal -ApplicationId $azureAdApplication.ApplicationId
    $servicePrincipal | Format-Table

    Write-OctopusSuccess "Azure Service Principal successfully created"
    $AzureApplicationId = $azureAdApplication.ApplicationId
}
else 
{
    Write-OctopusVerbose "The azue service principal $AzureServicePrincipalName already exists, creating a new password for Octopus Deploy to use."        
    New-AzADAppCredential -DisplayName "$AzureServicePrincipalName" -Password $securePassword -EndDate $endDate     
    Write-OctopusSuccess "Azure Service Principal successfully password successfully created."
    $AzureApplicationId = $ExistingApplication.ApplicationId
}

if ($null -eq $existingAccount)
{
    Write-OctopusVerbose "Now creating the account in Octopus Deploy."
    $tenantParticipation = "Untenanted"

    if ($OctopusTenantIdList.Count -gt 0)
    {
        $tenantParticipation = "TenantedOrUntenanted"
    }

    $jsonPayload = @{
        AccountType = "AzureServicePrincipal"
        AzureEnvironment = ""
        SubscriptionNumber = $azureSubscription.Id
        Password = @{
            HasValue = $true
            NewValue = $password
        }
        TenantId = $AzureTenantId
        ClientId = $AzureApplicationId
        ActiveDirectoryEndpointBaseUri = ""
        ResourceManagementEndpointBaseUri = ""
        Name = $OctopusAccountName
        Description = "Account created by the bootstrap script"
        TenantedDeploymentParticipation = $tenantParticipation
        TenantTags = @()
        TenantIds = @($OctopusTenantIdList)
        EnvironmentIds = @($OctopusEnvironmentIdList)
    }

    Write-OctopusVerbose "Adding Azure Service Principal that was just created to Octopus Deploy"    
    Invoke-OctopusApi -EndPoint "accounts" -item $jsonPayload -method "POST" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -OctopusURL $OctopusURL

    Write-OctopusSuccess "Successfully added the Azure Service Principal account to Octopus Deploy"
}
else 
{
    $existingAccount.Password.HasValue = $true    
    $existingAccount.Password.NewValue = $password

    Write-OctopusVerbose "Updating the existing account in Octopus Deploy to use the new service principal credentials"
    Invoke-OctopusApi -EndPoint "accounts/$($existingAccount.Id)" -item $existingAccount -method "PUT" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -OctopusURL $OctopusUrl
    Write-OctopusSuccess "Successfully updated Azure Service Principal account in Octopus Deploy"
}
