#Requires -Version 5.1

<#
.SYNOPSIS
    Applies an Offline Domain Join blob on the target machine (first boot).

.DESCRIPTION
    Runs on the new VM (e.g. via a VMware customization specification,
    a guestinfo property or a scheduled first-boot task). The script reads the
    Base64 blob from a file OR from a VMware guestinfo variable, writes it to a
    temporary file and calls "djoin /requestODJ".

    Result: the VM becomes a domain member WITHOUT contacting a DC and WITHOUT
    credentials. The double-hop problem does not occur because the computer
    account was already created server-side (on the Admin-AD server).

.PARAMETER BlobPath
    Path to a file containing the Base64 blob.

.PARAMETER GuestInfoKey
    Alternative source: name of the VMware guestinfo variable (default:
    'guestinfo.odjblob') from which the blob is read via vmtoolsd.

.PARAMETER NoReboot
    Suppresses the automatic reboot after a successful join.

.EXAMPLE
    .\Invoke-OfflineDomainJoinRequest.ps1 -BlobPath 'C:\Temp\odj.blob'

.EXAMPLE
    .\Invoke-OfflineDomainJoinRequest.ps1 -GuestInfoKey 'guestinfo.odjblob'

.NOTES
    Author: Jan Tiedemann
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'File')]
param
(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [ValidateNotNullOrEmpty()]
    [string]
    $BlobPath,

    [Parameter(Mandatory, ParameterSetName = 'GuestInfo')]
    [ValidateNotNullOrEmpty()]
    [string]
    $GuestInfoKey = 'guestinfo.odjblob',

    [Parameter()]
    [switch]
    $NoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Characters stripped from a transported blob: the byte-order mark (U+FEFF)
# plus surrounding whitespace. This mirrors the trimming in
# New-OfflineDomainJoinBlob so that a UTF-8/UTF-16 BOM which survives the
# round-trip (a blob file saved as UTF-8-with-BOM, or a guestinfo value) never
# leaks into the Unicode file handed to 'djoin /requestODJ /loadfile'. A stray
# U+FEFF in the payload would otherwise make djoin reject the blob.
$script:BlobTrimChars = [char[]]@([char]0xFEFF, [char]0x20, [char]0x0D, [char]0x0A, [char]0x09)

function Get-BlobFromGuestInfo
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $Key
    )

    $vmtoolsd = Join-Path -Path ${env:ProgramFiles} -ChildPath 'VMware\VMware Tools\vmtoolsd.exe'
    if (-not (Test-Path -LiteralPath $vmtoolsd))
    {
        throw "vmtoolsd.exe not found. Are VMware Tools installed? Path: $vmtoolsd"
    }

    $value = & $vmtoolsd --cmd "info-get $Key"
    if ([string]::IsNullOrWhiteSpace($value))
    {
        throw "guestinfo variable '$Key' is empty or not set."
    }

    return $value.Trim($script:BlobTrimChars)
}

$djoin = Join-Path -Path $env:SystemRoot -ChildPath 'System32\djoin.exe'
if (-not (Test-Path -LiteralPath $djoin))
{
    throw "djoin.exe was not found at '$djoin'."
}

# Obtain the blob (file or guestinfo).
if ($PSCmdlet.ParameterSetName -eq 'GuestInfo')
{
    Write-Verbose "Reading blob from guestinfo variable '$GuestInfoKey'."
    $blob = Get-BlobFromGuestInfo -Key $GuestInfoKey
}
else
{
    if (-not (Test-Path -LiteralPath $BlobPath))
    {
        throw "Blob file '$BlobPath' was not found."
    }
    Write-Verbose "Reading blob from file '$BlobPath'."
    # No -Encoding: Get-Content honours a leading BOM (UTF-8/UTF-16) and reads
    # plain ASCII/UTF-8 Base64 correctly. Any BOM that is not auto-consumed is
    # removed by the explicit U+FEFF trim below.
    $blob = (Get-Content -LiteralPath $BlobPath -Raw).Trim($script:BlobTrimChars)
}

# Write the blob to a temporary Unicode file for djoin.
$loadFile = Join-Path -Path $env:TEMP -ChildPath ("odj_apply_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))

try
{
    Set-Content -LiteralPath $loadFile -Value $blob -Encoding Unicode -NoNewline

    $arguments = @(
        '/requestODJ'
        '/loadfile'; $loadFile
        '/windowspath'; $env:SystemRoot
        '/localos'
    )

    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Apply Offline Domain Join'))
    {
        Write-Verbose 'Applying Offline Domain Join blob.'
        $output = & $djoin @arguments 2>&1
        if ($LASTEXITCODE -ne 0)
        {
            throw "djoin /requestODJ failed (ExitCode $LASTEXITCODE): $($output -join ' ')"
        }

        Write-Host 'Offline Domain Join applied successfully.' -ForegroundColor Green

        if (-not $NoReboot.IsPresent)
        {
            Write-Host 'Rebooting in 10 seconds to complete the domain join.' -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            Restart-Computer -Force
        }
    }
}
finally
{
    if (Test-Path -LiteralPath $loadFile)
    {
        Remove-Item -LiteralPath $loadFile -Force -ErrorAction SilentlyContinue
    }
}
