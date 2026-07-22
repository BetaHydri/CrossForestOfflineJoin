#Requires -Version 5.1

BeforeAll {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\OfflineJoin\OfflineJoin.psd1'
    Import-Module -Name (Resolve-Path -LiteralPath $manifest).Path -Force
}

AfterAll {
    Remove-Module -Name OfflineJoin -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-OdjUnattendXml' {

    BeforeAll {
        $script:Blob = 'QUJDRAo='
        $script:Xml = ConvertTo-OdjUnattendXml -BlobBase64 $script:Blob
    }

    It 'Returns a non-empty string' {
        $script:Xml | Should -Not -BeNullOrEmpty
    }

    It 'Produces well-formed XML' {
        { [xml]$script:Xml } | Should -Not -Throw
    }

    It 'Embeds the blob in the AccountData element' {
        ([xml]$script:Xml).settings.component.OfflineIdentification.Provisioning.AccountData |
            Should -Be $script:Blob
    }

    It 'Targets the offlineServicing pass and the UnattendedJoin component' {
        $doc = [xml]$script:Xml
        $doc.settings.pass | Should -Be 'offlineServicing'
        $doc.settings.component.name | Should -Be 'Microsoft-Windows-UnattendedJoin'
    }

    It 'Throws on an empty blob' {
        { ConvertTo-OdjUnattendXml -BlobBase64 '' } | Should -Throw
    }
}
