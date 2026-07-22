#Requires -Version 5.1

<#
.SYNOPSIS
    Core functions for the Offline Domain Join (ODJ) service.

.DESCRIPTION
    This module encapsulates the logic for creating and processing
    Offline Domain Join blobs (djoin.exe). It is used by both the
    command-line script and the web service.

    Security rationale:
    - The provisioning step (creating the computer account) runs locally on the
      Admin-AD server under the service's OWN identity (gMSA).
    - NO user credentials are forwarded to a second hop -> the double-hop
      problem is eliminated by design.
    - The generated blob contains the machine password and is a secret;
      it must be transported encrypted and treated as short-lived.

.NOTES
    Author: Jan Tiedemann
#>

Set-StrictMode -Version Latest

$script:MachineNamePattern = '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$'

function Test-OdjMachineName
{
    <#
    .SYNOPSIS
        Validates a computer name against NetBIOS rules (injection protection).

    .DESCRIPTION
        Allows only letters, digits and hyphens, with a maximum of 15 characters.
        This prevents parameter injection into djoin.exe and rejects invalid
        names (OWASP: input validation at the system boundary).

    .PARAMETER MachineName
        The computer name to validate (without domain suffix).

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $MachineName
    )

    return [bool]($MachineName -match $script:MachineNamePattern)
}

function Test-OdjDistinguishedName
{
    <#
    .SYNOPSIS
        Checks whether a string is a plausible LDAP DistinguishedName.

    .PARAMETER DistinguishedName
        The DN to validate (e.g. the target OU path).

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $DistinguishedName
    )

    # Must start with OU= or CN= and contain at least one DC= component.
    # Forbidden characters that hint at injection are rejected.
    if ($DistinguishedName -match '[\r\n\0"|&;`]')
    {
        return $false
    }

    return [bool]($DistinguishedName -match '^(OU|CN)=.+,DC=.+')
}

function New-OfflineDomainJoinBlob
{
    <#
    .SYNOPSIS
        Creates a computer account in the target domain and returns the ODJ blob.

    .DESCRIPTION
        Encapsulates "djoin.exe /provision". The call creates a computer account
        in the specified target domain and returns the Base64-encoded
        provisioning blob as its output.

        The identity running this code (typically a gMSA in the Admin-AD forest)
        needs the "Create Computer objects" and "Reset Password" rights in the
        target OU of the trusted forest. These rights are granted across the
        forest trust via OU delegation (see Set-CrossForestOuDelegation.ps1).

    .PARAMETER Domain
        FQDN of the target domain, e.g. "res-forest-a.example.com".

    .PARAMETER MachineName
        Name of the new computer (without domain suffix), max. 15 characters.

    .PARAMETER MachineOU
        DistinguishedName of the target OU in which the account is created.

    .PARAMETER DomainControllerName
        Optional DC to contact for provisioning.

    .PARAMETER Reuse
        Allows reuse of an already existing account.

    .PARAMETER RootCaCerts
        Embeds the root CA certificates into the blob (for NDES/CEP scenarios).

    .OUTPUTS
        PSCustomObject with the properties MachineName, Domain, MachineOU,
        BlobBase64 (the provisioning blob) and CreatedUtc.

    .EXAMPLE
        New-OfflineDomainJoinBlob -Domain 'res-a.example.com' -MachineName 'WEBVM01' -MachineOU 'OU=Server,DC=res-a,DC=example,DC=com'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Domain,

        [Parameter(Mandatory)]
        [ValidateScript({
                if (Test-OdjMachineName -MachineName $_) { $true }
                else { throw "Invalid computer name '$_'. Allowed: letters, digits, hyphen, max. 15 characters." }
            })]
        [string]
        $MachineName,

        [Parameter(Mandatory)]
        [ValidateScript({
                if (Test-OdjDistinguishedName -DistinguishedName $_) { $true }
                else { throw "Invalid OU DistinguishedName '$_'." }
            })]
        [string]
        $MachineOU,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $DomainControllerName,

        [Parameter()]
        [switch]
        $Reuse,

        [Parameter()]
        [switch]
        $RootCaCerts
    )

    $djoin = Join-Path -Path $env:SystemRoot -ChildPath 'System32\djoin.exe'
    if (-not (Test-Path -LiteralPath $djoin))
    {
        throw "djoin.exe was not found at '$djoin'."
    }

    # Temporary blob file in the service account's protected TEMP folder.
    $tempFile = Join-Path -Path $env:TEMP -ChildPath ("odj_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))

    $arguments = @(
        '/provision'
        '/domain'; $Domain
        '/machine'; $MachineName
        '/machineou'; $MachineOU
        '/savefile'; $tempFile
    )

    if ($PSBoundParameters.ContainsKey('DomainControllerName'))
    {
        $arguments += @('/dcname', $DomainControllerName)
    }

    if ($Reuse.IsPresent)
    {
        $arguments += '/reuse'
    }

    if ($RootCaCerts.IsPresent)
    {
        $arguments += '/rootcacerts'
    }

    if (-not $PSCmdlet.ShouldProcess("$MachineName in $Domain ($MachineOU)", 'Provision Offline Domain Join'))
    {
        return
    }

    try
    {
        Write-Verbose "Provisioning computer '$MachineName' in domain '$Domain'."

        # djoin writes text to stdout; the ExitCode is evaluated.
        $output = & $djoin @arguments 2>&1
        if ($LASTEXITCODE -ne 0)
        {
            throw "djoin /provision failed (ExitCode $LASTEXITCODE): $($output -join ' ')"
        }

        if (-not (Test-Path -LiteralPath $tempFile))
        {
            throw 'djoin did not produce a blob file.'
        }

        # The blob is Unicode text (Base64). Strip leading BOM/whitespace.
        $blob = (Get-Content -LiteralPath $tempFile -Raw -Encoding Unicode).Trim([char]0xFEFF, [char]0x20, [char]0x0D, [char]0x0A, [char]0x09)

        [PSCustomObject]@{
            MachineName = $MachineName
            Domain      = $Domain
            MachineOU   = $MachineOU
            BlobBase64  = $blob
            CreatedUtc  = [datetime]::UtcNow
        }
    }
    finally
    {
        if (Test-Path -LiteralPath $tempFile)
        {
            # Do not leave the secret behind: overwrite the file and delete it.
            try
            {
                $length = (Get-Item -LiteralPath $tempFile).Length
                if ($length -gt 0)
                {
                    [byte[]]$zero = New-Object byte[] $length
                    [System.IO.File]::WriteAllBytes($tempFile, $zero)
                }
            }
            catch
            {
                Write-Warning "Could not securely overwrite the temporary blob file: $($_.Exception.Message)"
            }
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-OdjUnattendXml
{
    <#
    .SYNOPSIS
        Embeds an ODJ blob into an unattend.xml fragment.

    .DESCRIPTION
        Generates the "Microsoft-Windows-UnattendedJoin" element for the
        "offlineServicing" pass. This lets a VMware template establish domain
        membership without DC contact and without credentials.

    .PARAMETER BlobBase64
        The Base64 blob returned by New-OfflineDomainJoinBlob.

    .OUTPUTS
        System.String (XML fragment)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BlobBase64
    )

    return @"
<settings pass="offlineServicing">
  <component name="Microsoft-Windows-UnattendedJoin"
             processorArchitecture="amd64"
             publicKeyToken="31bf3856ad364e35"
             language="neutral"
             versionScope="nonSxS">
    <OfflineIdentification>
      <Provisioning>
        <AccountData>$BlobBase64</AccountData>
      </Provisioning>
    </OfflineIdentification>
  </component>
</settings>
"@
}

Export-ModuleMember -Function @(
    'Test-OdjMachineName'
    'Test-OdjDistinguishedName'
    'New-OfflineDomainJoinBlob'
    'ConvertTo-OdjUnattendXml'
)
