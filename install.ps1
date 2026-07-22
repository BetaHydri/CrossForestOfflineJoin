#Requires -Version 5.1

<#
.SYNOPSIS
    One-stop installer that automates the setup of the Offline Domain Join
    (CrossForestOfflineJoin) service as far as possible.

.DESCRIPTION
    Orchestrates the individual setup steps that are otherwise run manually
    (see docs/quickstart.md). Every stage is idempotent and can be skipped, so
    the script can be re-run safely. Mutating actions honour -WhatIf / -Confirm.

    Stages (each guarded by a switch or by the presence of parameters):

      1. Prerequisite checks (elevation, ActiveDirectory + Pode modules).
      2. Install the Pode module          (-InstallPode).
      3. Ensure a KDS root key exists      (-CreateKdsRootKey).
      4. Ensure the hosts security group   (-CreateHostsGroup).
      5. Create the gMSA                   (-GmsaName / -GmsaDns).
      6. Install the gMSA on this host     (default; skip with -SkipGmsaInstall).
      7. Delegate the target OUs           (-SetOuDelegation, per -Target).
      8. Generate appsettings.local.psd1   (from -CertificateThumbprint,
         -ApiClientName/-ApiKey and -Target).
      9. Register the Windows service      (-RegisterService, needs nssm).

    Cross-forest note: OU delegation (stage 7) must run against each resource
    forest and requires a forest trust plus rights in that forest. If this host
    cannot write the target OU, run scripts/Set-CrossForestOuDelegation.ps1
    separately from within each forest.

.PARAMETER GmsaName
    SAM name of the gMSA (without '$'), e.g. 'gmsa-odjsvc'. Triggers stage 5/6.

.PARAMETER GmsaDns
    DNS host name of the gMSA, e.g. 'gmsa-odjsvc.admin-ad.example.com'.

.PARAMETER HostsGroupName
    Security group whose members (the host servers) may retrieve the gMSA
    password, e.g. 'GG-ODJ-Hosts'.

.PARAMETER CreateHostsGroup
    Create HostsGroupName as a global security group if it does not exist, and
    add this computer to it.

.PARAMETER CreateKdsRootKey
    Create a KDS root key if none exists. In a lab it is effective immediately;
    in production allow up to 10 hours of propagation.

.PARAMETER InstallPode
    Install the Pode module (Install-Module Pode -Scope AllUsers) if missing.

.PARAMETER SkipGmsaInstall
    Do not run Install-ADServiceAccount on this host (e.g. when generating the
    configuration on a management workstation).

.PARAMETER Target
    One or more provisioning targets. Each entry is a hashtable with the keys
    Domain, MachineOU and NamePrefix, e.g.
        @{ Domain = 'res-a.example.com'; MachineOU = 'OU=Server,DC=res-a,DC=example,DC=com'; NamePrefix = 'RESA' }
    Used to build AllowedTargets and (with -SetOuDelegation) to delegate OUs.

.PARAMETER SetOuDelegation
    Run scripts/Set-CrossForestOuDelegation.ps1 for every -Target. The gMSA
    (Admin-AD\<GmsaName>$) is delegated the minimal rights on each MachineOU.

.PARAMETER CertificateThumbprint
    Thumbprint of the TLS server certificate in LocalMachine\My.

.PARAMETER ApiClientName
    Friendly name of the initial API client (appears in the audit log).

.PARAMETER ApiKey
    API key of the initial client as a SecureString. Only its SHA256 hash is
    written to the configuration; the clear text is never stored.

.PARAMETER EndpointAddress
    Listen address of the HTTPS endpoint. Default '*'.

.PARAMETER Port
    HTTPS port. Default 8443.

.PARAMETER AuditLogPath
    Path of the audit log. Default 'C:\ProgramData\OfflineJoinService\audit.log'.

.PARAMETER ConfigPath
    Output path of the generated configuration. Default
    'src/WebService/appsettings.local.psd1' (git-ignored).

.PARAMETER RegisterService
    Register the Pode service as a Windows service under the gMSA using nssm.

.PARAMETER ServiceName
    Name of the Windows service to register. Default 'OfflineJoinService'.

.PARAMETER NssmPath
    Path to nssm.exe. Defaults to 'nssm' resolved from PATH.

.EXAMPLE
    # Full automated install on the Admin-AD host (lab):
    $key = Read-Host -AsSecureString 'API key'
    .\install.ps1 `
        -GmsaName 'gmsa-odjsvc' `
        -GmsaDns  'gmsa-odjsvc.admin-ad.example.com' `
        -HostsGroupName 'GG-ODJ-Hosts' -CreateHostsGroup -CreateKdsRootKey -InstallPode `
        -CertificateThumbprint 'ABCD...1234' `
        -ApiClientName 'vmware-aria-automation' -ApiKey $key `
        -Target @{ Domain='res-a.example.com'; MachineOU='OU=Server,DC=res-a,DC=example,DC=com'; NamePrefix='RESA' } `
        -RegisterService

.EXAMPLE
    # Only (re)generate the configuration file:
    $key = Read-Host -AsSecureString 'API key'
    .\install.ps1 -CertificateThumbprint 'ABCD...1234' -ApiClientName 'aria' -ApiKey $key `
        -Target @{ Domain='res-a.example.com'; MachineOU='OU=Server,DC=res-a,DC=example,DC=com'; NamePrefix='RESA' }

.NOTES
    Author: Jan Tiedemann
    Re-runnable and safe: existing objects are detected and left unchanged.
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter()]
    [string]
    $GmsaName,

    [Parameter()]
    [string]
    $GmsaDns,

    [Parameter()]
    [string]
    $HostsGroupName,

    [Parameter()]
    [switch]
    $CreateHostsGroup,

    [Parameter()]
    [switch]
    $CreateKdsRootKey,

    [Parameter()]
    [switch]
    $InstallPode,

    [Parameter()]
    [switch]
    $SkipGmsaInstall,

    [Parameter()]
    [hashtable[]]
    $Target,

    [Parameter()]
    [switch]
    $SetOuDelegation,

    [Parameter()]
    [string]
    $CertificateThumbprint,

    [Parameter()]
    [string]
    $ApiClientName,

    [Parameter()]
    [System.Security.SecureString]
    $ApiKey,

    [Parameter()]
    [string]
    $EndpointAddress = '*',

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]
    $Port = 8443,

    [Parameter()]
    [string]
    $AuditLogPath = 'C:\ProgramData\OfflineJoinService\audit.log',

    [Parameter()]
    [string]
    $ConfigPath,

    [Parameter()]
    [switch]
    $RegisterService,

    [Parameter()]
    [string]
    $ServiceName = 'OfflineJoinService',

    [Parameter()]
    [string]
    $NssmPath = 'nssm'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$scriptsDir = Join-Path -Path $scriptRoot -ChildPath 'scripts'
$webServiceDir = Join-Path -Path $scriptRoot -ChildPath 'src\WebService'
$startScript = Join-Path -Path $webServiceDir -ChildPath 'Start-OfflineJoinService.ps1'

if (-not $ConfigPath)
{
    $ConfigPath = Join-Path -Path $webServiceDir -ChildPath 'appsettings.local.psd1'
}

#region Helpers

function Test-IsElevated
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Stage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $Message
    )

    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertFrom-SecureStringPlain
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [System.Security.SecureString]
        $Secure
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try
    {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally
    {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

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

function Test-TargetEntry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [hashtable]
        $Entry
    )

    foreach ($k in 'Domain', 'MachineOU', 'NamePrefix')
    {
        if (-not $Entry.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$Entry[$k]))
        {
            throw "Target entry is missing the required key '$k'. Provide @{ Domain=...; MachineOU=...; NamePrefix=... }."
        }
    }
}

#endregion Helpers

#region 1. Prerequisites

Write-Stage 'Checking prerequisites'

$needsAdmin = $CreateKdsRootKey -or $CreateHostsGroup -or $GmsaName -or (-not $SkipGmsaInstall -and $GmsaName) -or $RegisterService
if ($needsAdmin -and -not (Test-IsElevated))
{
    throw 'This operation requires an elevated PowerShell session (Run as Administrator).'
}

$hasAdModule = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
$adStagesRequested = $CreateKdsRootKey -or $CreateHostsGroup -or $GmsaName -or $SetOuDelegation
if ($adStagesRequested -and -not $hasAdModule)
{
    throw 'The ActiveDirectory module (RSAT) is required for the requested AD stages but was not found.'
}
if ($hasAdModule)
{
    Import-Module -Name ActiveDirectory -ErrorAction Stop
}

#endregion 1. Prerequisites

#region 2. Pode

if ($InstallPode)
{
    Write-Stage 'Ensuring the Pode module is installed'
    if (Get-Module -ListAvailable -Name Pode)
    {
        Write-Host 'Pode is already installed.' -ForegroundColor Green
    }
    elseif ($PSCmdlet.ShouldProcess('Pode', 'Install-Module -Scope AllUsers'))
    {
        Install-Module -Name Pode -Scope AllUsers -Force -AllowClobber
        Write-Host 'Pode installed.' -ForegroundColor Green
    }
}

#endregion 2. Pode

#region 3. KDS root key

if ($CreateKdsRootKey)
{
    Write-Stage 'Ensuring a KDS root key exists'
    if (Get-KdsRootKey -ErrorAction SilentlyContinue)
    {
        Write-Host 'A KDS root key already exists.' -ForegroundColor Green
    }
    elseif ($PSCmdlet.ShouldProcess('KDS root key', 'Add-KdsRootKey'))
    {
        Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
        Write-Host 'KDS root key created (in production allow up to 10 hours before use).' -ForegroundColor Green
    }
}

#endregion 3. KDS root key

#region 4. Hosts group

if ($CreateHostsGroup)
{
    if (-not $HostsGroupName)
    {
        throw '-CreateHostsGroup requires -HostsGroupName.'
    }

    Write-Stage "Ensuring the hosts security group '$HostsGroupName'"
    $group = Get-ADGroup -Filter "Name -eq '$HostsGroupName'" -ErrorAction SilentlyContinue
    if (-not $group -and $PSCmdlet.ShouldProcess($HostsGroupName, 'Create global security group'))
    {
        $group = New-ADGroup -Name $HostsGroupName -GroupScope Global -GroupCategory Security -PassThru
        Write-Host "Group '$HostsGroupName' created." -ForegroundColor Green
    }

    $thisComputer = '{0}$' -f $env:COMPUTERNAME
    $isMember = Get-ADGroupMember -Identity $HostsGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.SamAccountName -eq $thisComputer }
    if (-not $isMember -and $PSCmdlet.ShouldProcess($thisComputer, "Add to '$HostsGroupName'"))
    {
        Add-ADGroupMember -Identity $HostsGroupName -Members (Get-ADComputer -Identity $env:COMPUTERNAME)
        Write-Host "Added '$thisComputer' to '$HostsGroupName'. A reboot may be required for the membership to take effect." -ForegroundColor Yellow
    }
}

#endregion 4. Hosts group

#region 5/6. gMSA

if ($GmsaName)
{
    if (-not $GmsaDns -or -not $HostsGroupName)
    {
        throw '-GmsaName requires -GmsaDns and -HostsGroupName.'
    }

    Write-Stage "Creating/verifying the gMSA '$GmsaName'"
    $newGmsa = Join-Path -Path $scriptsDir -ChildPath 'New-OfflineJoinGmsa.ps1'
    & $newGmsa -Name $GmsaName -Dns $GmsaDns -PrincipalsAllowedToRetrieveManagedPassword $HostsGroupName

    if (-not $SkipGmsaInstall)
    {
        Write-Stage "Installing the gMSA '$GmsaName' on this host"
        if ($PSCmdlet.ShouldProcess($GmsaName, 'Install-ADServiceAccount'))
        {
            Install-ADServiceAccount -Identity $GmsaName
            if (Test-ADServiceAccount -Identity $GmsaName)
            {
                Write-Host "gMSA '$GmsaName' installed and usable on this host." -ForegroundColor Green
            }
            else
            {
                Write-Warning "Test-ADServiceAccount returned False. Ensure this host is a member of '$HostsGroupName' (reboot may be required) and the KDS key is effective."
            }
        }
    }
}

#endregion 5/6. gMSA

#region 7. OU delegation

if ($SetOuDelegation)
{
    if (-not $Target)
    {
        throw '-SetOuDelegation requires at least one -Target.'
    }
    if (-not $GmsaName)
    {
        throw '-SetOuDelegation requires -GmsaName to derive the trustee (Admin-AD\<GmsaName>$).'
    }

    $adminNetbios = (Get-ADDomain).NetBIOSName
    $trustee = '{0}\{1}$' -f $adminNetbios, $GmsaName
    $delegationScript = Join-Path -Path $scriptsDir -ChildPath 'Set-CrossForestOuDelegation.ps1'

    foreach ($t in $Target)
    {
        Test-TargetEntry -Entry $t
        Write-Stage "Delegating OU '$($t.MachineOU)' to '$trustee'"
        Write-Warning "OU delegation must run with rights in the resource forest of '$($t.Domain)' (forest trust + name resolution required). If this host cannot write that OU, run scripts/Set-CrossForestOuDelegation.ps1 from within that forest instead."
        & $delegationScript -TargetOU $t.MachineOU -TrusteeSamAccountName $trustee
    }
}

#endregion 7. OU delegation

#region 8. Configuration

if ($CertificateThumbprint -or $ApiClientName -or $Target)
{
    Write-Stage "Generating configuration '$ConfigPath'"

    if (-not $CertificateThumbprint)
    {
        Write-Warning 'No -CertificateThumbprint supplied; a placeholder is written. HTTPS will not start until it is set.'
        $CertificateThumbprint = 'REPLACE-WITH-CERT-THUMBPRINT'
    }

    $apiClientsBlock = ''
    if ($ApiClientName -and $ApiKey)
    {
        $plain = ConvertFrom-SecureStringPlain -Secure $ApiKey
        try
        {
            $hash = Get-Sha256Hex -Value $plain
        }
        finally
        {
            $plain = $null
        }

        $apiClientsBlock = @"
        @{
            Name         = '$ApiClientName'
            ApiKeySha256 = '$hash'
        }
"@
    }
    else
    {
        Write-Warning 'No -ApiClientName/-ApiKey supplied; a placeholder API client is written. Set a real SHA256 hash before use.'
        $apiClientsBlock = @"
        @{
            Name         = 'REPLACE-WITH-CLIENT-NAME'
            ApiKeySha256 = 'REPLACE-WITH-SHA256-OF-API-KEY'
        }
"@
    }

    $targetsBlock = ''
    if ($Target)
    {
        $entries = foreach ($t in $Target)
        {
            Test-TargetEntry -Entry $t
            @"
        @{
            Domain     = '$($t.Domain)'
            MachineOU  = '$($t.MachineOU)'
            NamePrefix = '$($t.NamePrefix)'
        }
"@
        }
        $targetsBlock = $entries -join "`r`n"
    }
    else
    {
        $targetsBlock = @"
        @{
            Domain     = 'res-a.example.com'
            MachineOU  = 'OU=Server,DC=res-a,DC=example,DC=com'
            NamePrefix = 'RESA'
        }
"@
    }

    $content = @"
@{
    # Generated by install.ps1 on $([datetime]::UtcNow.ToString('o')).
    Endpoint       = @{
        Address               = '$EndpointAddress'
        Port                  = $Port
        CertificateThumbprint = '$CertificateThumbprint'
    }

    ApiClients     = @(
$apiClientsBlock
    )

    AllowedTargets = @(
$targetsBlock
    )

    AuditLogPath   = '$AuditLogPath'
}
"@

    $configDir = Split-Path -Path $ConfigPath -Parent
    if (-not (Test-Path -LiteralPath $configDir))
    {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($ConfigPath, 'Write configuration'))
    {
        Set-Content -LiteralPath $ConfigPath -Value $content -Encoding UTF8
        Write-Host "Configuration written to '$ConfigPath'." -ForegroundColor Green
    }
}

#endregion 8. Configuration

#region 9. Service registration

if ($RegisterService)
{
    Write-Stage "Registering the Windows service '$ServiceName' (nssm)"

    $nssm = Get-Command -Name $NssmPath -ErrorAction SilentlyContinue
    if (-not $nssm)
    {
        throw "nssm was not found (looked for '$NssmPath'). Download it from https://nssm.cc/ or pass -NssmPath."
    }
    if (-not $GmsaName)
    {
        throw '-RegisterService requires -GmsaName so the service can run under the gMSA.'
    }

    $pwsh = Get-Command -Name pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh)
    {
        $pwsh = Get-Command -Name powershell -ErrorAction Stop
    }
    $adminNetbios = (Get-ADDomain).NetBIOSName
    $serviceAccount = '{0}\{1}$' -f $adminNetbios, $GmsaName
    $appArgs = '-NoProfile -File "{0}" -ConfigPath "{1}"' -f $startScript, $ConfigPath

    if ($PSCmdlet.ShouldProcess($ServiceName, 'Register via nssm and start'))
    {
        & $nssm.Source install $ServiceName $pwsh.Source $appArgs
        & $nssm.Source set $ServiceName AppDirectory $scriptRoot
        & $nssm.Source set $ServiceName ObjectName $serviceAccount ''
        & $nssm.Source start $ServiceName
        Write-Host "Service '$ServiceName' registered under '$serviceAccount' and started." -ForegroundColor Green
    }
}

#endregion 9. Service registration

Write-Stage 'install.ps1 finished'
Write-Host 'Review the generated configuration and verify with a test request (see docs/quickstart.md, section 7).' -ForegroundColor Green
