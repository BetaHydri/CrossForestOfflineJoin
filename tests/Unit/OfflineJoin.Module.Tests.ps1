#Requires -Version 5.1

BeforeAll {
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\OfflineJoin\OfflineJoin.psd1'
    $script:ManifestPath = (Resolve-Path -LiteralPath $script:ManifestPath).Path
    Import-Module -Name $script:ManifestPath -Force
}

AfterAll {
    Remove-Module -Name OfflineJoin -Force -ErrorAction SilentlyContinue
}

Describe 'OfflineJoin module manifest' {

    It 'Is a valid module manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath } | Should -Not -Throw
    }

    It 'Declares PowerShell 5.1 as the minimum version' {
        $data = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
        $data.PowerShellVersion | Should -Be '5.1'
    }

    It 'Exports exactly the four public functions' {
        $expected = @(
            'ConvertTo-OdjUnattendXml'
            'New-OfflineDomainJoinBlob'
            'Test-OdjDistinguishedName'
            'Test-OdjMachineName'
        )
        $actual = (Get-Command -Module OfflineJoin -CommandType Function).Name | Sort-Object
        $actual | Should -Be $expected
    }
}
