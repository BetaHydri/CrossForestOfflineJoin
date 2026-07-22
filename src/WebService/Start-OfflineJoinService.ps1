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

    Optionally (WebUi.Enabled in appsettings) it also serves a browser form for
    AD admins at GET /ui, secured by IIS Windows Authentication and restricted to
    the members of a configured AD group. The form pre-populates the allowed
    domain/OU targets in a drop-down; the server never trusts the browser and
    re-validates every request against the same allow-list as the API.

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

# Web UI HTML builders (pure functions; kept separate for unit testing). Only
# needed when WebUi is enabled, but always available to the Pode runspaces.
. (Join-Path -Path $PSScriptRoot -ChildPath 'OfflineJoinWebUi.ps1')

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

    # Optional secured browser form for AD admins (IIS Windows Authentication).
    if ($config.ContainsKey('WebUi') -and $config.WebUi -and $config.WebUi.Enabled)
    {
        # Session middleware backs the anti-CSRF token.
        Enable-PodeSessionMiddleware -Duration 1800 -Extend

        # Windows identity is forwarded by IIS; only members of AdminGroup pass.
        Add-PodeAuthIIS -Name 'WebUiAuth' -Groups @($config.WebUi.AdminGroup)

        $uiBasePath = if ($config.WebUi.BasePath) { $config.WebUi.BasePath } else { '/ui' }

        Add-PodeRoute -Method Get -Path $uiBasePath -Authentication 'WebUiAuth' -ScriptBlock {
            $cfg = $using:config
            $basePath = if ($cfg.WebUi.BasePath) { $cfg.WebUi.BasePath } else { '/ui' }
            $token = [guid]::NewGuid().ToString('N')
            $WebEvent.Session.Data.csrf = $token
            $user = [string]$WebEvent.Auth.User.Username
            $body = Get-OdjFormBody -Targets @($cfg.AllowedTargets) -CsrfToken $token -User $user -BasePath $basePath
            Write-PodeHtmlResponse -Value (Get-OdjHtmlPage -Title 'Offline Domain Join' -Body $body)
        }

        Add-PodeRoute -Method Post -Path "$uiBasePath/provision" -Authentication 'WebUiAuth' -ScriptBlock {
            $cfg = $using:config
            $basePath = if ($cfg.WebUi.BasePath) { $cfg.WebUi.BasePath } else { '/ui' }
            $user = [string]$WebEvent.Auth.User.Username

            # Anti-CSRF: the posted token must match the one bound to the session.
            $posted = [string]$WebEvent.Data.csrf
            $expected = [string]$WebEvent.Session.Data.csrf
            if ([string]::IsNullOrEmpty($expected) -or $posted -ne $expected)
            {
                Write-AuditLine -Path $cfg.AuditLogPath -Message "DENY-UI csrf user=$user"
                Set-PodeResponseStatus -Code 403
                Write-PodeHtmlResponse -Value (Get-OdjHtmlPage -Title 'Denied' -Body '<h1>Request rejected</h1><p>Invalid or expired form token. Please reload the form.</p>')
                return
            }

            $machineName = [string]$WebEvent.Data.machineName
            $outputFormat = if ($WebEvent.Data.outputFormat) { [string]$WebEvent.Data.outputFormat } else { 'blob' }

            $idx = -1
            [void][int]::TryParse([string]$WebEvent.Data.targetIndex, [ref]$idx)
            $allowed = @($cfg.AllowedTargets)
            $target = $null
            if ($idx -ge 0 -and $idx -lt $allowed.Count)
            {
                $target = $allowed[$idx]
            }

            # Re-render the form with a fresh token and an error message.
            $renderError = {
                param($msg)
                $newToken = [guid]::NewGuid().ToString('N')
                $WebEvent.Session.Data.csrf = $newToken
                $b = Get-OdjFormBody -Targets $allowed -CsrfToken $newToken -User $user -BasePath $basePath -ErrorMessage $msg
                Write-PodeHtmlResponse -Value (Get-OdjHtmlPage -Title 'Offline Domain Join' -Body $b)
            }

            if (-not (Test-OdjMachineName -MachineName $machineName))
            {
                Write-AuditLine -Path $cfg.AuditLogPath -Message "DENY-UI invalid-name user=$user name=$machineName"
                Set-PodeResponseStatus -Code 400
                & $renderError 'Invalid computer name.'
                return
            }

            if ($null -eq $target)
            {
                Set-PodeResponseStatus -Code 400
                & $renderError 'Please select a valid target.'
                return
            }

            if (-not $machineName.StartsWith($target.NamePrefix, [System.StringComparison]::OrdinalIgnoreCase))
            {
                Write-AuditLine -Path $cfg.AuditLogPath -Message "DENY-UI prefix user=$user domain=$($target.Domain) name=$machineName"
                Set-PodeResponseStatus -Code 403
                & $renderError ("Computer name must start with '{0}' for this target." -f $target.NamePrefix)
                return
            }

            try
            {
                $result = New-OfflineDomainJoinBlob -Domain $target.Domain -MachineName $machineName -MachineOU $target.MachineOU
                Write-AuditLine -Path $cfg.AuditLogPath -Message "ALLOW-UI user=$user domain=$($target.Domain) name=$machineName ou=$($target.MachineOU)"

                $payload = if ($outputFormat.ToLowerInvariant() -eq 'unattend')
                {
                    ConvertTo-OdjUnattendXml -BlobBase64 $result.BlobBase64
                }
                else
                {
                    $result.BlobBase64
                }

                $body = Get-OdjResultBody -MachineName $result.MachineName -Domain $result.Domain -Payload $payload -BasePath $basePath
                Write-PodeHtmlResponse -Value (Get-OdjHtmlPage -Title 'Result' -Body $body)
            }
            catch
            {
                Write-AuditLine -Path $cfg.AuditLogPath -Message "ERROR-UI user=$user name=$machineName msg=$($_.Exception.Message)"
                Set-PodeResponseStatus -Code 500
                & $renderError 'Provisioning failed.'
            }
        }
    }
}
