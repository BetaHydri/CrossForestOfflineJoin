#Requires -Version 5.1

<#
.SYNOPSIS
    Structured audit-logging helpers for the Offline Domain Join web service.

.DESCRIPTION
    Provides a pure line formatter (Format-OdjAuditEvent) and a writer
    (Write-OdjAuditEvent) that appends the line to a file and, optionally, mirrors
    it to the Windows Event Log for central collection (e.g. via Windows Event
    Forwarding to a SIEM).

    The functions support BSI IT-Grundschutz OPS.1.1.5 (logging of
    security-relevant events):
    - Every event carries an ISO-8601 UTC timestamp, an event name and an
      outcome, plus optional structured fields (source IP, identity, target).
    - Values are sanitized against log-injection / log-forging: carriage return,
      line feed and tab are stripped so crafted input (e.g. a machine name or an
      X-Forwarded-For header) cannot inject fake audit lines.
    - No secret content (blob, machine password, API key) is ever logged.

    The helpers are intentionally free of external dependencies so they can be
    unit tested in isolation and used from within Pode route runspaces.

.NOTES
    Author: Jan Tiedemann
#>

Set-StrictMode -Version Latest

function ConvertTo-OdjAuditToken
{
    <#
    .SYNOPSIS
        Sanitizes a value for safe use in a single-line key=value audit record.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $Value
    )

    if ([string]::IsNullOrEmpty($Value))
    {
        return '-'
    }

    # Strip control characters (CR, LF, TAB) to prevent log-injection/forging.
    # Runs of control characters collapse to a single space so a CRLF pair does
    # not leave a double space in the record.
    $clean = ($Value -replace '[\r\n\t]+', ' ').Trim()

    if ([string]::IsNullOrEmpty($clean))
    {
        return '-'
    }

    return $clean
}

function Format-OdjAuditEvent
{
    <#
    .SYNOPSIS
        Builds a single, sanitized, structured audit line (pure function).

    .DESCRIPTION
        Produces a line of the form:

            2026-07-22T10:15:30.1234567Z  evt=<name> outcome=<outcome> [reason=<reason>] [<field>=<value> ...]

    .PARAMETER EventName
        The event category, e.g. 'provision', 'provision-ui', 'auth', 'service'.

    .PARAMETER Outcome
        The result, e.g. 'allow', 'deny', 'error', 'ok', 'fail', 'start', 'stop'.

    .PARAMETER Reason
        Optional short machine-readable reason, e.g. 'invalid-name',
        'not-allowed', 'csrf', 'invalid-api-key'.

    .PARAMETER Field
        Optional ordered dictionary of additional fields (order is preserved).

    .PARAMETER TimestampUtc
        The UTC timestamp of the event. Defaults to the current UTC time.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $EventName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Outcome,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $Reason,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary]
        $Field,

        [Parameter()]
        [datetime]
        $TimestampUtc = [datetime]::UtcNow
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendFormat(
        '{0:o}  evt={1} outcome={2}',
        $TimestampUtc.ToUniversalTime(),
        (ConvertTo-OdjAuditToken -Value $EventName),
        (ConvertTo-OdjAuditToken -Value $Outcome))

    if (-not [string]::IsNullOrEmpty($Reason))
    {
        [void]$sb.AppendFormat(' reason={0}', (ConvertTo-OdjAuditToken -Value $Reason))
    }

    if ($null -ne $Field)
    {
        foreach ($key in $Field.Keys)
        {
            $name = ConvertTo-OdjAuditToken -Value ([string]$key)
            $val = ConvertTo-OdjAuditToken -Value ([string]$Field[$key])
            [void]$sb.AppendFormat(' {0}={1}', $name, $val)
        }
    }

    return $sb.ToString()
}

function Get-OdjEventCategory
{
    <#
    .SYNOPSIS
        Maps an event name to a numbered Windows Event Log category (pure).

    .DESCRIPTION
        Windows Event Log categories are numbered sequentially starting at 1 and
        are normally described by a category message file (CategoryMessageFile).
        This solution ships no message DLL, so the Event Viewer shows the numeric
        category. The numbers still group events for filtering:
            1 = Authentication, 2 = Provisioning, 3 = Service. 0 = unclassified.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $EventName
    )

    switch -Regex ($EventName)
    {
        '^auth' { return 1 }
        '^provision' { return 2 }
        '^service' { return 3 }
        default { return 0 }
    }
}

function Write-OdjAuditEvent
{
    <#
    .SYNOPSIS
        Appends an audit line to a file and, optionally, to the Windows Event Log.

    .PARAMETER Path
        Path to the audit log file. The parent directory is created if missing.

    .PARAMETER Line
        The pre-formatted audit line (see Format-OdjAuditEvent).

    .PARAMETER EventLog
        Optional dictionary with keys 'Enabled', 'LogName' and 'Source'. When
        'Enabled' is true, the line is also written to the Windows Event Log.
        Any Event Log failure (e.g. missing permission to create the source
        under the gMSA) is swallowed so file auditing never breaks.

    .PARAMETER EntryType
        Windows Event Log entry type. One of Information, Warning, Error.

    .PARAMETER EventId
        Windows Event Log event id.

    .PARAMETER Category
        Windows Event Log category number (see Get-OdjEventCategory). Categories
        render numerically in Event Viewer because no category message file is
        shipped; the number still groups events for filtering.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [string]
        $Line,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary]
        $EventLog,

        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]
        $EntryType = 'Information',

        [Parameter()]
        [int]
        $EventId = 1000,

        [Parameter()]
        [int]
        $Category = 0
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir))
    {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8

    if ($null -ne $EventLog -and $EventLog.Contains('Enabled') -and $EventLog['Enabled'])
    {
        try
        {
            $logName = if ($EventLog.Contains('LogName') -and $EventLog['LogName'])
            {
                [string]$EventLog['LogName']
            }
            else
            {
                'Application'
            }

            $source = if ($EventLog.Contains('Source') -and $EventLog['Source'])
            {
                [string]$EventLog['Source']
            }
            else
            {
                'OfflineJoinService'
            }

            # Registering an event source is a privileged, one-time operation and
            # should normally be done at install time (see install.ps1). This
            # runtime attempt is a best-effort fallback and may fail under a
            # low-privilege service identity such as the gMSA.
            if (-not [System.Diagnostics.EventLog]::SourceExists($source))
            {
                [System.Diagnostics.EventLog]::CreateEventSource($source, $logName)
            }

            Write-EventLog -LogName $logName -Source $source -EntryType $EntryType -EventId $EventId -Category $Category -Message $Line
        }
        catch
        {
            # File auditing must never fail because of Event Log issues.
        }
    }
}

function Get-OdjClientAddress
{
    <#
    .SYNOPSIS
        Determines the best-known client source address for an audit record.

    .DESCRIPTION
        Returns the left-most X-Forwarded-For entry when present (the original
        client behind a trusted reverse proxy such as IIS), otherwise the direct
        remote endpoint address. Returns '-' when nothing can be determined. The
        value is later sanitized by Format-OdjAuditEvent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter()]
        [AllowNull()]
        $WebEvent
    )

    $remote = '-'
    try
    {
        if ($WebEvent -and $WebEvent.Request -and $WebEvent.Request.RemoteEndPoint)
        {
            $remote = [string]$WebEvent.Request.RemoteEndPoint.Address
        }
    }
    catch
    {
        $remote = '-'
    }

    $xff = $null
    try
    {
        if ($WebEvent -and $WebEvent.Request -and $WebEvent.Request.Headers)
        {
            $xff = [string]$WebEvent.Request.Headers['X-Forwarded-For']
        }
    }
    catch
    {
        $xff = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($xff))
    {
        $first = ($xff -split ',')[0].Trim()
        if (-not [string]::IsNullOrWhiteSpace($first))
        {
            return $first
        }
    }

    return $remote
}
