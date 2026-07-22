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

# Structured audit-logging helpers (pure formatter + file/Event-Log writer).
# Kept separate so they can be unit tested in isolation. Supports BSI
# IT-Grundschutz OPS.1.1.5 (security-relevant events, log-injection safe).
$loggingScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'OfflineJoinLogging.ps1'
. $loggingScriptPath

function Write-OdjAudit
{
    <#
    .SYNOPSIS
        Formats and writes an audit event using the configured file (and the
        optional Windows Event Log). Thin wrapper over Format-OdjAuditEvent and
        Write-OdjAuditEvent so route script blocks stay concise.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]
        $Config,

        [Parameter(Mandatory)]
        [string]
        $EventName,

        [Parameter(Mandatory)]
        [string]
        $Outcome,

        [Parameter()]
        [string]
        $Reason,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary]
        $Field,

        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]
        $EntryType = 'Information',

        [Parameter()]
        [int]
        $EventId = 1000
    )

    $line = Format-OdjAuditEvent -EventName $EventName -Outcome $Outcome -Reason $Reason -Field $Field
    $category = Get-OdjEventCategory -EventName $EventName

    $eventLog = $null
    if ($Config.Contains('Logging') -and $Config['Logging'] -and $Config['Logging'].Contains('EventLog'))
    {
        $eventLog = $Config['Logging'].EventLog
    }

    Write-OdjAuditEvent -Path $Config.AuditLogPath -Line $line -EventLog $eventLog -EntryType $EntryType -EventId $EventId -Category $category
}

# Web UI HTML builders (pure functions; kept separate for unit testing). Only
# needed when WebUi is enabled, but always available to the Pode runspaces.
$webUiScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'OfflineJoinWebUi.ps1'
. $webUiScriptPath

Start-PodeServer {

    # Surface unhandled route/auth exceptions on the console instead of only
    # returning a generic HTTP 500 page, so failures are diagnosable.
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging

    # Pode routes and auth handlers execute in separate runspaces that only
    # auto-import functions defined in THIS script file. The audit-logging and
    # HTML-builder helpers live in separately dot-sourced files, so their
    # functions (Format-OdjAuditEvent, Get-OdjFormBody, Get-OdjLoginBody, etc.)
    # are invisible to those runspaces and cause a generic HTTP 500. Registering
    # the files via Use-PodeScript imports their functions into every runspace.
    Use-PodeScript -Path $loggingScriptPath
    Use-PodeScript -Path $webUiScriptPath

    # The certificate is looked up by thumbprint in a certificate store. The
    # store location defaults to LocalMachine (where the setup/install steps
    # place the server certificate); Pode itself would otherwise default to
    # CurrentUser\My and fail to find a LocalMachine certificate. Both the
    # store name and location can be overridden in appsettings if needed.
    $certStoreName = 'My'
    if ($config.Endpoint.Contains('CertificateStoreName') -and $config.Endpoint.CertificateStoreName)
    {
        $certStoreName = $config.Endpoint.CertificateStoreName
    }

    $certStoreLocation = 'LocalMachine'
    if ($config.Endpoint.Contains('CertificateStoreLocation') -and $config.Endpoint.CertificateStoreLocation)
    {
        $certStoreLocation = $config.Endpoint.CertificateStoreLocation
    }

    Add-PodeEndpoint -Address $config.Endpoint.Address `
        -Port $config.Endpoint.Port `
        -Protocol Https `
        -CertificateThumbprint $config.Endpoint.CertificateThumbprint `
        -CertificateStoreName $certStoreName `
        -CertificateStoreLocation $certStoreLocation

    # Service lifecycle: record start (BSI OPS.1.1.5) and, best-effort, stop.
    Write-OdjAudit -Config $config -EventName 'service' -Outcome 'start' `
        -Field ([ordered]@{ address = [string]$config.Endpoint.Address; port = [string]$config.Endpoint.Port }) -EventId 4100

    try
    {
        Register-PodeEvent -Type Stop -Name 'OfflineJoinServiceStop' -ScriptBlock {
            $cfg = $using:config
            try
            {
                Write-OdjAudit -Config $cfg -EventName 'service' -Outcome 'stop' -EventId 4101
            }
            catch
            {
                # Best-effort shutdown logging; never block the stop sequence.
            }
        }
    }
    catch
    {
        # Register-PodeEvent may be unavailable in some Pode versions; ignore.
    }

    # API-key authentication via the 'X-Api-Key' header. Sessionless because
    # this is a stateless REST API: every request carries its own key and no
    # session cookie is issued (avoids requiring Enable-PodeSessionMiddleware).
    New-PodeAuthScheme -ApiKey -Location Header -LocationName 'X-Api-Key' |
        Add-PodeAuth -Name 'ApiKeyAuth' -Sessionless -ScriptBlock {
            param($key)

            $cfg = $using:config
            $ip = Get-OdjClientAddress -WebEvent $WebEvent

            $presentedHash = Get-Sha256Hex -Value $key
            $client = $cfg.ApiClients |
                Where-Object { $_.ApiKeySha256.ToLowerInvariant() -eq $presentedHash }

            if ($null -eq $client)
            {
                Write-OdjAudit -Config $cfg -EventName 'auth' -Outcome 'fail' -Reason 'invalid-api-key' `
                    -Field ([ordered]@{ ip = $ip }) -EntryType 'Warning' -EventId 4010
                return $null
            }

            Write-OdjAudit -Config $cfg -EventName 'auth' -Outcome 'ok' `
                -Field ([ordered]@{ ip = $ip; client = [string]$client.Name }) -EventId 4011

            return @{ User = @{ Name = $client.Name } }
        }

    Add-PodeRoute -Method Post -Path '/api/v1/provision' -Authentication 'ApiKeyAuth' -ScriptBlock {

        $cfg = $using:config
        $body = $WebEvent.Data
        $ip = Get-OdjClientAddress -WebEvent $WebEvent

        $machineName = [string]$body.machineName
        $domain = [string]$body.domain
        $outputFormat = if ($body.outputFormat) { [string]$body.outputFormat } else { 'blob' }
        $client = $WebEvent.Auth.User.Name

        # 1) Input validation.
        if (-not (Test-OdjMachineName -MachineName $machineName))
        {
            Write-OdjAudit -Config $cfg -EventName 'provision' -Outcome 'deny' -Reason 'invalid-name' `
                -Field ([ordered]@{ ip = $ip; client = $client; name = $machineName }) -EntryType 'Warning' -EventId 4001
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
            Write-OdjAudit -Config $cfg -EventName 'provision' -Outcome 'deny' -Reason 'not-allowed' `
                -Field ([ordered]@{ ip = $ip; client = $client; domain = $domain; name = $machineName }) -EntryType 'Warning' -EventId 4002
            Set-PodeResponseStatus -Code 403
            Write-PodeJsonResponse -Value @{ error = 'Target not in the allow-list.' }
            return
        }

        # 3) Provision.
        try
        {
            $result = New-OfflineDomainJoinBlob -Domain $target.Domain -MachineName $machineName -MachineOU $target.MachineOU

            Write-OdjAudit -Config $cfg -EventName 'provision' -Outcome 'allow' `
                -Field ([ordered]@{ ip = $ip; client = $client; domain = $domain; name = $machineName; ou = [string]$target.MachineOU }) -EventId 4000

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
            Write-OdjAudit -Config $cfg -EventName 'provision' -Outcome 'error' -Reason 'provision-failed' `
                -Field ([ordered]@{ ip = $ip; client = $client; name = $machineName; msg = [string]$_.Exception.Message }) -EntryType 'Error' -EventId 4003
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = 'Provisioning failed.' }
        }
    }

    # Optional secured browser form for AD admins. Two authentication modes are
    # supported through WebUi.AuthMode:
    #   'WindowsAd' (default) - standalone HTTPS: a hosted HTML login form
    #                collects AD credentials that are validated directly against
    #                Active Directory over the TLS channel and backed by a
    #                server-side session cookie. No IIS needed.
    #   'IIS'      - the Windows identity is forwarded by IIS's ASP.NET Core
    #                Module (MS-ASPNETCORE-WINAUTHTOKEN) when the service is
    #                hosted behind IIS with Windows Authentication.
    # Both modes restrict access to members of AdminGroup.
    if ($config.ContainsKey('WebUi') -and $config.WebUi -and $config.WebUi.Enabled)
    {
        # Session middleware backs the anti-CSRF token and the login cookie.
        Enable-PodeSessionMiddleware -Duration 1800 -Extend

        $uiBasePath = if ($config.WebUi.BasePath) { $config.WebUi.BasePath } else { '/ui' }

        $uiAuthMode = 'WindowsAd'
        if ($config.WebUi.Contains('AuthMode') -and $config.WebUi.AuthMode)
        {
            $uiAuthMode = [string]$config.WebUi.AuthMode
        }

        # Protected UI routes redirect to the login form only in standalone mode;
        # under IIS the identity is always present, so no login page is used.
        $uiRouteAuth = @{ Authentication = 'WebUiAuth' }

        if ($uiAuthMode -eq 'IIS')
        {
            # Windows identity is forwarded by IIS; only members of AdminGroup pass.
            Add-PodeAuthIIS -Name 'WebUiAuth' -Groups @($config.WebUi.AdminGroup)
        }
        else
        {
            # Standalone: hosted HTML login form. Credentials are validated
            # against Active Directory over the TLS channel, restricted to
            # AdminGroup, and backed by a server-side session cookie.
            New-PodeAuthScheme -Form |
                Add-PodeAuthWindowsAd -Name 'WebUiAuth' -Groups @($config.WebUi.AdminGroup) `
                    -FailureUrl "$uiBasePath/login?failed=1" -SuccessUrl $uiBasePath

            $uiRouteAuth.Login = $true

            # Login page (GET renders the form; POST validates the credentials).
            Add-PodeRoute -Method Get -Path "$uiBasePath/login" -Authentication 'WebUiAuth' -Login -ScriptBlock {
                $cfg = $using:config
                $basePath = if ($cfg.WebUi.BasePath) { $cfg.WebUi.BasePath } else { '/ui' }
                $err = if ($WebEvent.Query.failed) { 'Sign-in failed. Check your credentials or contact an administrator.' } else { $null }
                $body = Get-OdjLoginBody -BasePath $basePath -ErrorMessage $err
                Write-PodeHtmlResponse -Value (Get-OdjHtmlPage -Title 'Sign in' -Body $body)
            }

            Add-PodeRoute -Method Post -Path "$uiBasePath/login" -Authentication 'WebUiAuth' -Login

            Add-PodeRoute -Method Post -Path "$uiBasePath/logout" -Authentication 'WebUiAuth' -Logout
        }

        Add-PodeRoute -Method Get -Path $uiBasePath @uiRouteAuth -ScriptBlock {
            $cfg = $using:config
            $basePath = if ($cfg.WebUi.BasePath) { $cfg.WebUi.BasePath } else { '/ui' }
            $token = [guid]::NewGuid().ToString('N')
            $WebEvent.Session.Data.csrf = $token
            $user = [string]$WebEvent.Auth.User.Username
            $body = Get-OdjFormBody -Targets @($cfg.AllowedTargets) -CsrfToken $token -User $user -BasePath $basePath
            Write-PodeHtmlResponse -Value (Get-OdjHtmlPage -Title 'Offline Domain Join' -Body $body)
        }

        Add-PodeRoute -Method Post -Path "$uiBasePath/provision" @uiRouteAuth -ScriptBlock {
            $cfg = $using:config
            $basePath = if ($cfg.WebUi.BasePath) { $cfg.WebUi.BasePath } else { '/ui' }
            $user = [string]$WebEvent.Auth.User.Username
            $ip = Get-OdjClientAddress -WebEvent $WebEvent

            # Anti-CSRF: the posted token must match the one bound to the session.
            $posted = [string]$WebEvent.Data.csrf
            $expected = [string]$WebEvent.Session.Data.csrf
            if ([string]::IsNullOrEmpty($expected) -or $posted -ne $expected)
            {
                Write-OdjAudit -Config $cfg -EventName 'provision-ui' -Outcome 'deny' -Reason 'csrf' `
                    -Field ([ordered]@{ ip = $ip; user = $user }) -EntryType 'Warning' -EventId 4021
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
                Write-OdjAudit -Config $cfg -EventName 'provision-ui' -Outcome 'deny' -Reason 'invalid-name' `
                    -Field ([ordered]@{ ip = $ip; user = $user; name = $machineName }) -EntryType 'Warning' -EventId 4022
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
                Write-OdjAudit -Config $cfg -EventName 'provision-ui' -Outcome 'deny' -Reason 'prefix' `
                    -Field ([ordered]@{ ip = $ip; user = $user; domain = [string]$target.Domain; name = $machineName }) -EntryType 'Warning' -EventId 4023
                Set-PodeResponseStatus -Code 403
                & $renderError ("Computer name must start with '{0}' for this target." -f $target.NamePrefix)
                return
            }

            try
            {
                $result = New-OfflineDomainJoinBlob -Domain $target.Domain -MachineName $machineName -MachineOU $target.MachineOU
                Write-OdjAudit -Config $cfg -EventName 'provision-ui' -Outcome 'allow' `
                    -Field ([ordered]@{ ip = $ip; user = $user; domain = [string]$target.Domain; name = $machineName; ou = [string]$target.MachineOU }) -EventId 4020

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
                Write-OdjAudit -Config $cfg -EventName 'provision-ui' -Outcome 'error' -Reason 'provision-failed' `
                    -Field ([ordered]@{ ip = $ip; user = $user; name = $machineName; msg = [string]$_.Exception.Message }) -EntryType 'Error' -EventId 4024
                Set-PodeResponseStatus -Code 500
                & $renderError 'Provisioning failed.'
            }
        }
    }
}
