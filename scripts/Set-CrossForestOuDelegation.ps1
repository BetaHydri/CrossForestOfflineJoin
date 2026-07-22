#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Delegates to a foreign-forest identity the right to create computer
    accounts and reset passwords in a target OU.

.DESCRIPTION
    This script is run IN THE RESPECTIVE RESOURCE FOREST (target forest).
    It sets the access control list (ACL) of the target OU so that the
    specified identity (the gMSA of the ODJ service from the Admin-AD forest)
    receives the minimum rights required for "djoin /provision":

      - Create computer objects (Create Child: computer)
      - Reset Password on descendant computer objects
      - Write account restrictions / DNS host name / SPN

    A (at least incoming) forest trust from the target forest to the Admin-AD
    forest is required so that the foreign identity can be resolved.

    Least privilege: only the target OU is delegated, not the whole domain.

    The script reads and writes the target OU's security descriptor with the
    ActiveDirectory module's Get-ADObject / Set-ADObject cmdlets rather than the
    AD: PowerShell drive. The AD: drive is bound to the local host's own domain
    and returns "A referral was returned from the server." for a
    DistinguishedName in a different (child or foreign) domain. With -Server (a
    DC of the target domain) and optional -Credential the cmdlets follow the
    referral, so the delegation can be applied remotely from the Admin-AD host.

.PARAMETER TargetOU
    DistinguishedName of the target OU in the resource forest.

.PARAMETER TrusteeSamAccountName
    Foreign identity in the format 'ADMIN-AD\gmsa-odjsvc$'.

.PARAMETER Server
    Optional DNS name (or FQDN) of a domain controller of the TARGET domain.
    Required when the target OU lives in a different domain than the host this
    script runs on (child domain or foreign forest); otherwise the AD referral
    cannot be followed. If omitted, the caller's default domain is used.

.PARAMETER Credential
    Optional credentials with write rights on the target OU (e.g. the domain
    administrator of the resource domain). Use this to apply the delegation
    remotely from the Admin-AD host against a child or foreign domain.

.EXAMPLE
    .\Set-CrossForestOuDelegation.ps1 -TargetOU 'OU=Server,DC=res-a,DC=example,DC=com' -TrusteeSamAccountName 'ADMIN-AD\gmsa-odjsvc$'

.EXAMPLE
    # Remote delegation from the Admin-AD host against a foreign domain:
    $cred = Get-Credential 'RES-A\Administrator'
    .\Set-CrossForestOuDelegation.ps1 `
        -TargetOU 'OU=Server,DC=res-a,DC=example,DC=com' `
        -TrusteeSamAccountName 'ADMIN-AD\gmsa-odjsvc$' `
        -Server 'dc1.res-a.example.com' -Credential $cred

.NOTES
    Author: Jan Tiedemann
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $TargetOU,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]
    $TrusteeSamAccountName,

    [Parameter()]
    [string]
    $Server,

    [Parameter()]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Well-known schema GUIDs
$guidComputerClass = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # computer
$guidResetPassword = [guid]'00299570-246d-11d0-a768-00aa006e0529' # extended right: Reset Password
$guidAllProperties = [guid]'00000000-0000-0000-0000-000000000000' # all

# Resolve the foreign principal (requires the trust + name resolution).
$account = New-Object System.Security.Principal.NTAccount($TrusteeSamAccountName)
$sid = $account.Translate([System.Security.Principal.SecurityIdentifier])

# Build the AD cmdlet parameters. -Server (a DC of the target domain) and the
# optional -Credential let the delegation be applied remotely from the Admin-AD
# host against a child domain or foreign forest: Get-ADObject / Set-ADObject
# follow the referral that the AD: drive cannot.
$adParams = @{ }
if ($Server)
{
    $adParams['Server'] = $Server
}
if ($Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty)
{
    $adParams['Credential'] = $Credential
}

try
{
    $adObject = Get-ADObject -Identity $TargetOU -Properties 'nTSecurityDescriptor' @adParams
}
catch
{
    throw "Target OU '$TargetOU' could not be read (server '$Server'): $($_.Exception.Message)"
}

$acl = $adObject.nTSecurityDescriptor

# 1) Create/Delete computer child on the OU itself.
$aceCreate = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    ([System.DirectoryServices.ActiveDirectoryRights]::CreateChild -bor [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild),
    [System.Security.AccessControl.AccessControlType]::Allow,
    $guidComputerClass,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
)

# 2) Reset password on descendant computer objects.
$aceReset = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $guidResetPassword,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
    $guidComputerClass
)

# 3) Write all properties on descendant computer objects
#    (covers dNSHostName, servicePrincipalName, userAccountControl).
$aceWrite = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
    [System.Security.AccessControl.AccessControlType]::Allow,
    $guidAllProperties,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
    $guidComputerClass
)

$acl.AddAccessRule($aceCreate)
$acl.AddAccessRule($aceReset)
$acl.AddAccessRule($aceWrite)

if ($PSCmdlet.ShouldProcess($TargetOU, "Set delegation for '$TrusteeSamAccountName'"))
{
    Set-ADObject -Identity $TargetOU -Replace @{ nTSecurityDescriptor = $acl } -Confirm:$false @adParams
    Write-Host "Delegation for '$TrusteeSamAccountName' set on '$TargetOU'." -ForegroundColor Green
}
