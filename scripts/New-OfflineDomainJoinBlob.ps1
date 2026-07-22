#Requires -Version 5.1

<#
.SYNOPSIS
    Creates an Offline Domain Join blob from the command line.

.DESCRIPTION
    Thin wrapper around the module function New-OfflineDomainJoinBlob for
    interactive or scripted use on the Admin-AD server. Returns either the raw
    blob, an unattend.xml fragment or an object with all metadata.

.PARAMETER Domain
    FQDN of the target domain.

.PARAMETER MachineName
    Name of the new computer (max. 15 characters).

.PARAMETER MachineOU
    DistinguishedName of the target OU.

.PARAMETER OutputFormat
    Blob (raw Base64 blob), Unattend (XML fragment) or Object (metadata).

.EXAMPLE
    .\New-OfflineDomainJoinBlob.ps1 -Domain 'res-a.example.com' -MachineName 'WEBVM01' -MachineOU 'OU=Server,DC=res-a,DC=example,DC=com' -OutputFormat Unattend

.NOTES
    Author: Jan Tiedemann
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Domain,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $MachineName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $MachineOU,

    [Parameter()]
    [ValidateSet('Blob', 'Unattend', 'Object')]
    [string]
    $OutputFormat = 'Object'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\OfflineJoin\OfflineJoin.psd1'
Import-Module -Name $modulePath -Force

$result = New-OfflineDomainJoinBlob -Domain $Domain -MachineName $MachineName -MachineOU $MachineOU

switch ($OutputFormat)
{
    'Blob' { $result.BlobBase64 }
    'Unattend' { ConvertTo-OdjUnattendXml -BlobBase64 $result.BlobBase64 }
    'Object' { $result }
}
