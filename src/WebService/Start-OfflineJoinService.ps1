#Requires -Version 5.1
#Requires -Modules Pode

<#
.SYNOPSIS
    REST web service that generates Offline Domain Join blobs for requesting
    systems (e.g. VMware automation).

.DESCRIPTION
    The service runs on the Admin-AD server under a gMSA and exposes a single,
    secured endpoint:

        POST /api/v1/provision
        {
            "machineName": "RESA-WEB01",
            "domain":      "res-a.example.com",
            "outputFormat": "blob"     // blob | unattend
        }

    Flow:
    1. TLS + API-key authentication of the requester.
    2. Validation against the allow-list (domain/OU/name prefix).
    3. Call New-OfflineDomainJoinBlob (djoin /provision) under the gMSA
       identity, which is authorized via cross-forest OU delegation.
    4. Return the blob or the unattend fragment over TLS.

    Security (OWASP):
    - Authentication + authorization (API key, HTTPS only).
    - Strict input validation (name pattern, allow-list) -> injection protection.
    - Least privilege of the service identity (only delegated OUs).
    - Audit log without secret content.

.PARAMETER ConfigPath
    Path to appsettings.psd1. Default: next to this script.

.EXAMPLE
    .\Start-OfflineJoinService.ps1

.NOTES
    Author: Jan Tiedemann

    Requires the Pode module (Install-Module Pode). Register it as a Windows
    service under the gMSA (e.g. with nssm or New-Service + Task Scheduler).
#>
[CmdletBinding()]
param
(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]
    $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'appsettings.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\OfflineJoin\OfflineJoin.psd1'
Import-Module -Name $modulePath -Force

if (-not (Test-Path -LiteralPath $ConfigPath))
{
    throw "Configuration file '$ConfigPath' was not found."
}
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath

function Get-Sha256Hex
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally
    {
        $sha.Dispose()
    }
}

function Write-AuditLine
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter(Mandatory)]
        [string]
        $Message
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir))
    {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $line = '{0:o}  {1}' -f [datetime]::UtcNow, $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

Start-PodeServer {

    Add-PodeEndpoint -Address $config.Endpoint.Address `
        -Port $config.Endpoint.Port `
        -Protocol Https `
        -CertificateThumbprint $config.Endpoint.CertificateThumbprint

    # API-key authentication via the 'X-Api-Key' header.
    New-PodeAuthScheme -ApiKey -Location Header -LocationName 'X-Api-Key' |
        Add-PodeAuth -Name 'ApiKeyAuth' -ScriptBlock {
            param($key)

            $presentedHash = Get-Sha256Hex -Value $key
            $client = $using:config.ApiClients |
                Where-Object { $_.ApiKeySha256.ToLowerInvariant() -eq $presentedHash }

            if ($null -eq $client)
            {
                return $null
            }

            return @{ User = @{ Name = $client.Name } }
        }

    Add-PodeRoute -Method Post -Path '/api/v1/provision' -Authentication 'ApiKeyAuth' -ScriptBlock {

        $cfg = $using:config
        $body = $WebEvent.Data

        $machineName = [string]$body.machineName
        $domain = [string]$body.domain
        $outputFormat = if ($body.outputFormat) { [string]$body.outputFormat } else { 'blob' }
        $client = $WebEvent.Auth.User.Name

        # 1) Input validation.
        if (-not (Test-OdjMachineName -MachineName $machineName))
        {
            Write-AuditLine -Path $cfg.AuditLogPath -Message "DENY invalid-name client=$client name=$machineName"
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = 'Invalid computer name.' }
            return
        }

        # 2) Authorization against the allow-list.
        $target = $cfg.AllowedTargets |
            Where-Object { $_.Domain -eq $domain -and $machineName.StartsWith($_.NamePrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1

        if ($null -eq $target)
        {
            Write-AuditLine -Path $cfg.AuditLogPath -Message "DENY not-allowed client=$client domain=$domain name=$machineName"
            Set-PodeResponseStatus -Code 403
            Write-PodeJsonResponse -Value @{ error = 'Target not in the allow-list.' }
            return
        }

        # 3) Provision.
        try
        {
            $result = New-OfflineDomainJoinBlob -Domain $target.Domain -MachineName $machineName -MachineOU $target.MachineOU

            Write-AuditLine -Path $cfg.AuditLogPath -Message "ALLOW client=$client domain=$domain name=$machineName ou=$($target.MachineOU)"

            switch ($outputFormat.ToLowerInvariant())
            {
                'unattend'
                {
                    $xml = ConvertTo-OdjUnattendXml -BlobBase64 $result.BlobBase64
                    Write-PodeJsonResponse -Value @{
                        machineName = $result.MachineName
                        domain      = $result.Domain
                        unattendXml = $xml
                    }
                }
                default
                {
                    Write-PodeJsonResponse -Value @{
                        machineName = $result.MachineName
                        domain      = $result.Domain
                        blobBase64  = $result.BlobBase64
                    }
                }
            }
        }
        catch
        {
            Write-AuditLine -Path $cfg.AuditLogPath -Message "ERROR client=$client name=$machineName msg=$($_.Exception.Message)"
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = 'Provisioning failed.' }
        }
    }
}
