[CmdletBinding()]
param()

if (Get-Module BcContainerHelper -ListAvailable) {
    Import-Module BcContainerHelper -Force
    if ($env:BC_CONTAINER_NAME -and
        (Get-BcContainerId -ContainerName $env:BC_CONTAINER_NAME)) {
        Remove-BcContainer -ContainerName $env:BC_CONTAINER_NAME
    }
}
