[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module BcContainerHelper -Force

$artifactUrl = Get-BcArtifactUrl -Type Sandbox -Country w1 -Select Latest `
    -StorageAccount bcinsider -Accept_InsiderEula
if (-not $artifactUrl -or [string]$artifactUrl -notmatch '(?i)bcinsider') {
    throw "Could not resolve a BCInsider Platform master sandbox artifact: '$artifactUrl'."
}

$containerName = 'al-public-triage'
$passwordText = [guid]::NewGuid().ToString('N') + 'aA1!'
Write-Host "::add-mask::$passwordText"
$credential = [pscredential]::new(
    'admin',
    (ConvertTo-SecureString $passwordText -AsPlainText -Force)
)

New-BcContainer `
    -Accept_Eula `
    -Accept_InsiderEula `
    -ContainerName $containerName `
    -ArtifactUrl $artifactUrl `
    -Auth UserPassword `
    -Credential $credential `
    -UpdateHosts `
    -Shortcuts None `
    -IncludeAL

if (-not (Get-BcContainerId -ContainerName $containerName)) {
    throw "Business Central container '$containerName' was not created."
}

"BC_CONTAINER_NAME=$containerName" | Add-Content -Path $env:GITHUB_ENV
"BC_ARTIFACT_URL=$artifactUrl" | Add-Content -Path $env:GITHUB_ENV
"BC_SERVER_URL=http://$containerName" | Add-Content -Path $env:GITHUB_ENV
"BC_SERVER_INSTANCE=BC" | Add-Content -Path $env:GITHUB_ENV
"BC_SERVER_PORT=7049" | Add-Content -Path $env:GITHUB_ENV
"BC_TENANT=default" | Add-Content -Path $env:GITHUB_ENV
"BC_AUTHENTICATION=UserPassword" | Add-Content -Path $env:GITHUB_ENV
"BC_SERVER_USERNAME=admin" | Add-Content -Path $env:GITHUB_ENV
"BC_SERVER_PASSWORD=$passwordText" | Add-Content -Path $env:GITHUB_ENV
