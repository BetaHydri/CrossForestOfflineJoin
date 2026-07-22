#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Creates the group Managed Service Account (gMSA) identity for the
    Offline Domain Join service.

.DESCRIPTION
    The ODJ service runs under a gMSA in the Admin-AD forest. The gMSA
    intentionally holds NO elevated rights; the permission to create computer
    accounts is granted later per target OU via delegation
    (Set-CrossForestOuDelegation.ps1).

    Prerequisites:
    - KDS root key present in the Admin-AD forest
      (Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))).
    - Run with permission to create service accounts.

.PARAMETER Name
    SAM name of the gMSA (without '$'), e.g. 'gmsa-odjsvc'.

.PARAMETER Dns
    DNS host name of the gMSA, e.g. 'gmsa-odjsvc.admin-ad.example.com'.

.PARAMETER PrincipalsAllowedToRetrieveManagedPassword
    Security group of the host servers allowed to retrieve the gMSA password.

.EXAMPLE
    .\New-OfflineJoinGmsa.ps1 -Name 'gmsa-odjsvc' -Dns 'gmsa-odjsvc.admin-ad.example.com' -PrincipalsAllowedToRetrieveManagedPassword 'GG-ODJ-Hosts'

.NOTES
    Author: Jan Tiedemann
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Name,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Dns,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $PrincipalsAllowedToRetrieveManagedPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-KdsRootKey -ErrorAction SilentlyContinue))
{
    throw 'No KDS root key present. Please run "Add-KdsRootKey" first (note the propagation delay of up to 10 hours).'
}

$existing = Get-ADServiceAccount -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue
if ($existing)
{
    Write-Warning "gMSA '$Name' already exists. No changes are made."
    return
}

if ($PSCmdlet.ShouldProcess($Name, 'Create gMSA'))
{
    New-ADServiceAccount -Name $Name `
        -DNSHostName $Dns `
        -PrincipalsAllowedToRetrieveManagedPassword $PrincipalsAllowedToRetrieveManagedPassword `
        -KerberosEncryptionType AES128, AES256 `
        -Enabled $true

    Write-Verbose "gMSA '$Name' was created."
    Write-Host "gMSA '$Name`$' created. On the host servers run: Install-ADServiceAccount -Identity '$Name'." -ForegroundColor Green
}
