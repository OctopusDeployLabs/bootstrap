param (
    $OctopusURL,
    $OctopusApiKey,
    $OctopusSpaceName,
    $AzureTenantId
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

    try
    {
        if ($null -eq $item)
        {           
            Write-OctopusVerbose "Invoking GET $url" 
            return Invoke-RestMethod -Method $method -Uri $url -Headers @{"X-Octopus-ApiKey" = "$ApiKey" } -ContentType 'application/json; charset=utf-8'
        }

        $body = $item | ConvertTo-Json -Depth 10        

        Write-OctopusVerbose "Invoking $method $url"
        return Invoke-RestMethod -Method $method -Uri $url -Headers @{"X-Octopus-ApiKey" = "$ApiKey" } -Body $body -ContentType 'application/json; charset=utf-8'
    }
    catch
    {
        if ($null -ne $_.Exception.Response)
        {
            $result = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($result)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            $responseBody = $reader.ReadToEnd();
            Write-OctopusVerbose -Message "Error calling $url $($_.Exception.Message) StatusCode: $($_.Exception.Response.StatusCode.value__ ) StatusDescription: $($_.Exception.Response.StatusDescription) $responseBody"
        }
        else
        {
            Write-OctopusVerbose $_.Exception
        }
    }

    Throw "There was an error calling the Octopus API please check the log for more details"
}

function Get-OctopusItemByName
{
    param (
        $ItemList,
        $ItemName
        )    

    return ($ItemList | Where-Object {$_.Name -eq $ItemName})
}

Write-OctopusVerbose "This script will do the following:"
Write-OctopusVerbose "    1) In Azure: create an Azure Service Principal and associate it with your desired subscription as a contributor"
Write-OctopusVerbose "    2) In Octopus Deploy: create an Azure Account using the credentials created in step 1"
Write-OctopusVerbose "    3) Optional in Azure: create a worker running in a container and register it with Octopus Deploy"

Write-OctopusVerbose "For this to work you will need to have the following installed.  If it is not installed, then this script will it install it for you."
Write-OctopusVerbose "    1)  Azure Az Powershell Modules"

$answer = Read-Host -Prompt "Do you wish to continue? y/n"
if ($answer -ne "y")
{
    Write-OctopusWarning "You have chosen not to continue.  Stopping script."
    Exit
}

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

$OctopusURL = Get-ParameterValue -originalParameterValue $OctopusURL -parameterName "the URL of your Octopus Deploy Instance, example: https://samples.octopus.com"
$OctopusApiKey = Get-ParameterValue -originalParameterValue $OctopusApiKey -parameterName "the API Key of your Octopus Deploy User.  See https://octopus.com/docs/octopus-rest-api/how-to-create-an-api-key for a guide on how to create one"
$OctopusSpaceName = Get-ParameterValue -originalParameterValue $OctopusSpaceName -parameterName "the name of the space in Octopus Deploy.  Enter Default if unsure"

Write-OctopusVerbose "Testing the API crendentials of the credentials supplied by pulling the space information"
$spaceResults = Invoke-OctopusApi -EndPoint "spaces?skip=0&take=100000" -SpaceId $null -OctopusURL $OctopusURL -apiKey $OctopusApiKey -method "Get" -item $null
$spaceInfo = Get-OctopusItemByName -ItemList $spaceResults.Items -ItemName $OctopusSpaceName
if ($null -ne $spaceInfo -and $null -ne $spaceInfo.Id)
{
    Write-OctopusSuccess "Successfully connected to the Octopus Deploy instance provided.  The space id for $OctopusSpaceName is $($spaceInfo.Id)"
}
else
{
    Write-OctopusWarning "Unable to connect to $OctopusUrl.  Please check your credentials and try again."
    exit 1
}

$accountName = "Bootstrap Azure Account"

$existingOctopusAccounts = Invoke-OctopusApi -EndPoint "accounts?skip=0&take=1000000" -method "GET" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -OctopusURL $OctopusURL
$existingAccount = Get-OctopusItemByName -ItemList $existingOctopusAccounts.Items -ItemName $accountName
$OctopusAndAzureServicePrincipalAlreadyExist = $false

if ($null -ne $existingAccount)
{
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
        Write-OctopusVerbose "Checking on the status of the task in 3 seconds."
        Start-Sleep -Seconds 3
        $taskStatus = Invoke-OctopusApi -EndPoint $taskStatusEndPoint -SpaceId $null -OctopusURL $OctopusURL -apiKey $OctopusApiKey -method "GET"        
        $taskState = $taskStatus.State

        Write-Host "The task status is $taskState"
        $taskDone = $taskState -eq "Success" -or $taskState -eq "Canceled" -or $taskState -eq "Failed"

        if ($taskState -eq "Success")
        {
            $OctopusAndAzureServicePrincipalAlreadyExist = $true
            Write-OctopusSuccess "The Octopus Account can successfully connect to Azure, skipping."
        }
    }    
}

$AzureTenantId = Get-ParameterValue -originalParameterValue $AzureTenantId -parameterName "the ID (GUID) of the Azure tenant you wish to connect to.  See https://microsoft.github.io/AzureTipsAndTricks/blog/tip153.html on how to get that id."
$AzureSubscriptionName = Get-ParameterValue -originalParameterValue $AzureSubscriptionName -parameterName "the name of the subscription you wish to connect Octopus Deploy to"
$AzureServicePrincipalName = Get-ParameterValue -originalParameterValue $AzureServicePrincipalName -parameterName "the name of the service principal you wish to create in Azure"

Write-OctopusVerbose "Logging into Azure"
Connect-AzAccount -Tenant $AzureTenantId -Subscription $AzureSubscriptionName

if ($OctopusAndAzureServicePrincipalAlreadyExist -eq $false)
{
    Write-Host "The service principal account or the Octopus Account do not exist or they haven't been hooked up.  Configuring Azure and Octopus Deploy."
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

        Write-OctopusSuccess "Azure Service Principal successfully created."
    }
    else 
    {
        Write-OctopusVerbose "The azue service principal $AzureServicePrincipalName already exists, creating a new password for Octopus Deploy to use."        
        New-AzADAppCredential -DisplayName "$AzureServicePrincipalName" -Password $securePassword -EndDate $endDate     
        Write-OctopusSuccess "Azure Service Principal successfully password successfully created."
    }

    if ($null -eq $existingAccount)
    {
        Write-OctopusVerbose "The account $accountName does not exist, creating it"
        $jsonPayload = @{
            AccountType = "AzureServicePrincipal"
            AzureEnvironment = ""
            SubscriptionNumber = $azureSubscription.Id
            Password = @{
                HasValue = $true
                NewValue = $password
            }
            TenantId = $AzureTenantId
            ClientId = $azureAdApplication.ApplicationId
            ActiveDirectoryEndpointBaseUri = ""
            ResourceManagementEndpointBaseUri = ""
            Name = $accountName
            Description = "Account created by the bootstrap script"
            TenantedDeploymentParticipation = "Untenanted"
            TenantTags = @()
            TenantIds = @()
            EnvironmentIds = @()
        }

        Write-OctopusVerbose "Adding the just created Azure Service Principal to Octopus Deploy"
        Invoke-OctopusApi -EndPoint "accounts" -item $jsonPayload -method "POST" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -OctopusURL $OctopusURL

        Write-OctopusSuccess "Successfully added the Azure Service Principal account to Octopus Deploy"
    }
    else 
    {
        $existingAccount.Password.HasValue = $true    
        $existingAccount.Password.NewValue = $password

        Invoke-OctopusApi -EndPoint "accounts/$($existingAccount.Id)" -item $existingAccount -method "PUT" -SpaceId $spaceInfo.Id -apiKey $OctopusApiKey -OctopusURL $OctopusUrl
    }
}

$createWorker = Read-Host "Would you like to create a Octopus Deploy worker in Azure?  It will spin up a Linux based container in Azure Container Service.  This will allow you to run Octopus Deployments to Azure PaaS services without having to open them up to Octopus Cloud.  y/n"
if ($createWorker -eq "n")
{
    Write-OctopusWarning "You have elected to not create a worker, stopping script."
    Exit
}
