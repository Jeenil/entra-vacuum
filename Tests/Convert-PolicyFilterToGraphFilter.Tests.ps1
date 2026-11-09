BeforeAll {
    Import-Module "$PSScriptRoot/../EntraVacuum/EntraVacuum.psd1" -Force
}

Describe 'Convert-PolicyFilterToGraphFilter (private)' {
    It 'strips user. prefix and converts -eq to eq' {
        $result = InModuleScope EntraVacuum { Convert-PolicyFilterToGraphFilter -PolicyFilter 'user.department -eq "Engineering"' }
        $result | Should -Be "department eq 'Engineering'"
    }

    It 'handles -and correctly' {
        $result = InModuleScope EntraVacuum { Convert-PolicyFilterToGraphFilter -PolicyFilter 'user.department -eq "Eng" -and user.country -eq "CA"' }
        $result | Should -Be "department eq 'Eng' and country eq 'CA'"
    }

    It 'maps extensionAttribute to onPremisesExtensionAttributes' {
        $result = InModuleScope EntraVacuum { Convert-PolicyFilterToGraphFilter -PolicyFilter 'user.extensionAttribute1 -eq "Contractor"' }
        $result | Should -Be "onPremisesExtensionAttributes/extensionAttribute1 eq 'Contractor'"
    }

    It 'returns null for empty filter' {
        $result = InModuleScope EntraVacuum { Convert-PolicyFilterToGraphFilter -PolicyFilter '' }
        $result | Should -BeNullOrEmpty
    }

    It 'converts -match and -notMatch on a plain prefix to startsWith' {
        $rule = '(user.accountEnabled -eq true) -and (user.userPrincipalName -notMatch "^admin_") -and (user.displayName -match "^AZ_")'
        $result = InModuleScope EntraVacuum -Parameters @{ Rule = $rule } { Convert-PolicyFilterToGraphFilter -PolicyFilter $Rule }
        $result | Should -Be "(accountEnabled eq true) and (not(startsWith(userPrincipalName,'admin_'))) and (startsWith(displayName,'AZ_'))"
    }

    It 'throws on an operator it cannot translate' {
        { InModuleScope EntraVacuum { Convert-PolicyFilterToGraphFilter -PolicyFilter 'user.department -contains "Eng"' } } | Should -Throw
        { InModuleScope EntraVacuum { Convert-PolicyFilterToGraphFilter -PolicyFilter 'user.mail -notMatch "@(a|b)\.com"' } } | Should -Throw
    }
}
