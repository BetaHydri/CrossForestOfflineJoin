@{
    RootModule        = 'OfflineJoin.psm1'
    ModuleVersion     = '1.6.1'
    GUID              = 'b6f4d3a1-7c2e-4e9b-9a1f-5d3c8e2a1b90'
    Author            = 'Jan Tiedemann'
    CompanyName       = 'Internal'
    Copyright         = '(c) Internal. All rights reserved.'
    Description       = 'Core functions for the Offline Domain Join service (djoin wrapper, blob creation, unattend generation).'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Test-OdjMachineName'
        'Test-OdjDistinguishedName'
        'New-OfflineDomainJoinBlob'
        'ConvertTo-OdjUnattendXml'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'OfflineDomainJoin', 'djoin', 'VMware', 'gMSA')
            ProjectUri = ''
        }
    }
}
