BeforeAll {
    $script:modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' | Join-Path -ChildPath 'lib' | Join-Path -ChildPath 'PatchStatusReport.psm1'
    Import-Module -Name $script:modulePath -Force

    function New-FakeHistoryEntry {
        param(
            [datetime]$Fecha = (Get-Date).AddDays(-10),
            [string]$Titulo = '2024-05 Cumulative Update for Windows (KB5000001)',
            [string]$KB = '',
            [string]$Resultado = 'Correcto',
            [string]$Categoria = ''
        )

        return [pscustomobject]@{
            Fecha     = $Fecha
            Titulo    = $Titulo
            KB        = $KB
            Resultado = $Resultado
            Categoria = $Categoria
        }
    }
}

Describe 'PatchStatusReport' {

    Context 'Get-InstalledUpdateHistory' {

        It 'normaliza los datos simulados, extrae el KB y traduce el ResultCode' {
            $history = Get-InstalledUpdateHistory -InputObject @(
                @{
                    Fecha      = (Get-Date).AddDays(-3)
                    Titulo     = '2024-05 Security Update for Windows (KB5001234)'
                    ResultCode = 2
                },
                @{
                    Fecha      = (Get-Date).AddDays(-5)
                    Titulo     = '2024-04 Cumulative Update for Windows (KB5004321)'
                    ResultCode = 4
                }
            )

            $history.Count | Should -Be 2
            $history[0].KB | Should -Be 'KB5001234'
            $history[0].Resultado | Should -Be 'Correcto'
            $history[0].Categoria | Should -Be 'Seguridad'
            $history[1].Resultado | Should -Be 'Fallido'
        }

        It 'traduce el código 3 y el código 5' {
            $history = Get-InstalledUpdateHistory -InputObject @(
                @{ Fecha = (Get-Date).AddDays(-1); Titulo = 'Update KB1'; Resultado = 3 },
                @{ Fecha = (Get-Date).AddDays(-2); Titulo = 'Update KB2'; Resultado = 5 }
            )

            $history[0].Resultado | Should -Be 'Con errores'
            $history[1].Resultado | Should -Be 'Cancelado'
        }

        It 'clasifica como Otra una actualización que no es de seguridad' {
            $history = Get-InstalledUpdateHistory -InputObject @(
                @{ Fecha = (Get-Date).AddDays(-1); Titulo = 'Driver de impresora'; Resultado = 2 }
            )

            $history[0].Categoria | Should -Be 'Otra'
            $history[0].KB | Should -BeNullOrEmpty
        }

        It 'lee el historial real sin lanzar excepción' {
            { Get-InstalledUpdateHistory -MaxEntries 20 } | Should -Not -Throw
        }
    }

    Context 'Test-LastPatch' {

        It 'devuelve OK si la última actualización de seguridad es reciente' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-10) -Titulo 'Security Update KB5000001')
            )

            $result = Test-LastPatch -History $history -WarnDays 35 -AlertDays 60

            $result.Estado | Should -Be 'OK'
            $result.Comprobacion | Should -Be 'Último parche'
        }

        It 'devuelve Aviso si han pasado más de WarnDays' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-40) -Titulo 'Cumulative Update KB5000002')
            )

            $result = Test-LastPatch -History $history -WarnDays 35 -AlertDays 60

            $result.Estado | Should -Be 'Aviso'
            $result.Detalle | Should -Match '35 días'
        }

        It 'devuelve Alta si han pasado más de AlertDays' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-70) -Titulo 'Security Update KB5000003')
            )

            $result = Test-LastPatch -History $history -WarnDays 35 -AlertDays 60

            $result.Estado | Should -Be 'Alta'
        }

        It 'devuelve Alta si no hay ninguna actualización de seguridad' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-2) -Titulo 'Driver de vídeo' -Categoria 'Otra')
            )

            $result = Test-LastPatch -History $history -WarnDays 35 -AlertDays 60

            $result.Estado | Should -Be 'Alta'
            $result.Valor | Should -Be 'Ninguna'
        }

        It 'ignora actualizaciones fallidas al buscar la última instalada' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-2) -Titulo 'Security Update KB5000004' -Resultado 'Fallido'),
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-80) -Titulo 'Security Update KB5000005' -Resultado 'Correcto')
            )

            $result = Test-LastPatch -History $history -WarnDays 35 -AlertDays 60

            $result.Estado | Should -Be 'Alta'
        }

        It 'devuelve Alta con el historial vacío' {
            $result = Test-LastPatch -History @() -WarnDays 35 -AlertDays 60

            $result.Estado | Should -Be 'Alta'
        }
    }

    Context 'Test-FailedUpdates' {

        It 'avisa de una actualización fallida reciente y lista el KB' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-10) -Titulo 'Security Update KB5000010' -Resultado 'Fallido')
            )

            $result = Test-FailedUpdates -History $history

            $result.Estado | Should -Be 'Aviso'
            $result.Valor | Should -Match 'KB5000010'
        }

        It 'no avisa si la misma KB se instaló después con éxito' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-10) -Titulo 'Security Update KB5000011' -Resultado 'Fallido'),
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-2) -Titulo 'Security Update KB5000011' -Resultado 'Correcto')
            )

            $result = Test-FailedUpdates -History $history

            $result.Estado | Should -Be 'OK'
        }

        It 'ignora fallos con más de 30 días' {
            $history = @(
                (New-FakeHistoryEntry -Fecha (Get-Date).AddDays(-60) -Titulo 'Security Update KB5000012' -Resultado 'Fallido')
            )

            $result = Test-FailedUpdates -History $history

            $result.Estado | Should -Be 'OK'
        }

        It 'devuelve OK sin historial' {
            (Test-FailedUpdates -History @()).Estado | Should -Be 'OK'
        }
    }

    Context 'Get-PendingUpdates' {

        It 'normaliza los datos simulados de pendientes' {
            $pending = Get-PendingUpdates -InputObject @(
                @{
                    Titulo          = '2024-05 Cumulative Update (KB5000020)'
                    Severidad       = 'Critical'
                    MaxDownloadSize = 104857600
                    IsMandatory     = $true
                }
            )

            @($pending).Count | Should -Be 1
            $pending[0].KB | Should -Be 'KB5000020'
            $pending[0].TamanoMB | Should -Be 100
            $pending[0].Obligatoria | Should -BeTrue
        }

        It 'no consulta en línea con -SkipOnlineSearch' {
            $pending = Get-PendingUpdates -SkipOnlineSearch

            $pending.Count | Should -Be 0
        }
    }

    Context 'Test-PendingUpdates' {

        It 'devuelve Alta si hay una actualización crítica' {
            $result = Test-PendingUpdates -Pending @(
                @{ Titulo = 'Actualización crítica'; KB = 'KB5000031'; Severidad = 'Critical' }
            )

            $result.Estado | Should -Be 'Alta'
            $result.Valor | Should -Match 'KB5000031'
        }

        It 'devuelve Aviso si hay una actualización Important' {
            $result = Test-PendingUpdates -Pending @(
                @{ Titulo = 'Actualización importante'; KB = 'KB5000032'; Severidad = 'Important' }
            )

            $result.Estado | Should -Be 'Aviso'
            $result.Detalle | Should -Match 'Important'
        }

        It 'devuelve Aviso si hay otras actualizaciones pendientes' {
            $result = Test-PendingUpdates -Pending @(
                @{ Titulo = 'Actualización opcional'; KB = 'KB5000033'; Severidad = 'Moderate' }
            )

            $result.Estado | Should -Be 'Aviso'
        }

        It 'devuelve OK si no hay pendientes' {
            (Test-PendingUpdates -Pending @()).Estado | Should -Be 'OK'
        }
    }

    Context 'Test-PendingReboot' {

        It 'devuelve Aviso e indica las claves si hay reinicio pendiente' {
            $result = Test-PendingReboot -InputObject @{
                CbsRebootPending               = $true
                WindowsUpdateRebootRequired    = $false
                PendingFileRenameOperations    = @()
            }

            $result.Estado | Should -Be 'Aviso'
            $result.Valor | Should -Match 'CBS'
        }

        It 'devuelve Aviso si hay PendingFileRenameOperations' {
            $result = Test-PendingReboot -InputObject @{
                CbsRebootPending            = $false
                WindowsUpdateRebootRequired = $false
                PendingFileRenameOperations = @('\??\C:\Windows\Temp\demo.tmp')
            }

            $result.Estado | Should -Be 'Aviso'
            $result.Valor | Should -Match 'PendingFileRenameOperations'
        }

        It 'devuelve OK si no hay nada pendiente' {
            $result = Test-PendingReboot -InputObject @{
                CbsRebootPending            = $false
                WindowsUpdateRebootRequired = $false
                PendingFileRenameOperations = @()
            }

            $result.Estado | Should -Be 'OK'
        }

        It 'lee el registro real sin lanzar excepción' {
            { Test-PendingReboot } | Should -Not -Throw
        }
    }

    Context 'Test-UpdatePolicy' {

        It 'devuelve Alta si NoAutoUpdate = 1' {
            $result = Test-UpdatePolicy -InputObject @{ NoAutoUpdate = 1; AUOptions = 2 }

            $result.Estado | Should -Be 'Alta'
            $result.Detalle | Should -Match 'desactivadas por directiva'
        }

        It 'informa de WSUS si está configurado' {
            $result = Test-UpdatePolicy -InputObject @{
                NoAutoUpdate = 0
                AUOptions    = 4
                WUServer     = 'https://wsus.demo.local:8531'
            }

            $result.Estado | Should -Be 'OK'
            $result.Detalle | Should -Match 'WSUS'
        }

        It 'devuelve OK sin directiva restrictiva' {
            $result = Test-UpdatePolicy -InputObject @{ NoAutoUpdate = 0; AUOptions = 4 }

            $result.Estado | Should -Be 'OK'
        }

        It 'lee las directivas reales sin lanzar excepción' {
            { Test-UpdatePolicy } | Should -Not -Throw
        }
    }

    Context 'Test-UpdateService' {

        It 'devuelve Alta si wuauserv está deshabilitado' {
            $result = Test-UpdateService -InputObject @{ StartType = 'Disabled' }

            $result.Estado | Should -Be 'Alta'
            $result.Valor | Should -Match 'Disabled'
        }

        It 'devuelve OK si wuauserv es automático' {
            (Test-UpdateService -InputObject @{ StartType = 'Automatic' }).Estado | Should -Be 'OK'
        }

        It 'lee el servicio real sin lanzar excepción' {
            { Test-UpdateService } | Should -Not -Throw
        }
    }

    Context 'Get-Uptime' {

        It 'devuelve OK si el equipo lleva pocos días encendido' {
            $result = Get-Uptime -InputObject (Get-Date).AddDays(-10)

            $result.Estado | Should -Be 'OK'
        }

        It 'devuelve Aviso si lleva más de 30 días encendido' {
            $result = Get-Uptime -InputObject (Get-Date).AddDays(-45)

            $result.Estado | Should -Be 'Aviso'
            $result.Detalle | Should -Match 'kernel'
        }

        It 'lee el último arranque real sin lanzar excepción' {
            { Get-Uptime } | Should -Not -Throw
        }
    }

    Context 'Export-PatchStatusReport' {

        It 'escribe patch-status.json y report.html con los textos escapados y las tablas' {
            $findings = @(
                [pscustomobject]@{
                    Comprobacion = '<script>alert(1)</script>'
                    Estado       = 'Alta'
                    Detalle      = 'Detalle con & y <b>etiquetas</b>'
                    Valor        = '70 días'
                    Recomendado  = 'Parchear'
                    Solucion     = 'Ejemplo'
                }
            )

            $history = New-Object System.Collections.Generic.List[object]
            for ($i = 1; $i -le 20; $i++) {
                $history.Add([pscustomobject]@{
                    Fecha     = (Get-Date).AddDays(-$i)
                    Titulo    = ('Actualización demo {0:d2}' -f $i)
                    KB        = ('KB50001{0:d2}' -f $i)
                    Resultado = 'Correcto'
                    Categoria = 'Seguridad'
                })
            }

            $pending = @(
                [pscustomobject]@{
                    Titulo      = 'Pendiente demo <b>'
                    KB          = 'KB5009999'
                    Severidad   = 'Critical'
                    TamanoMB    = 12.5
                    Obligatoria = $true
                }
            )

            $outputDir = Join-Path -Path $TestDrive -ChildPath 'salida'
            $result = Export-PatchStatusReport -Findings $findings -History $history.ToArray() -Pending $pending -OutputPath $outputDir -Notes @('Nota <de> prueba') -WarnDays 35 -AlertDays 60

            Test-Path -LiteralPath $result.Json | Should -BeTrue
            Test-Path -LiteralPath $result.Html | Should -BeTrue

            $html = Get-Content -LiteralPath $result.Html -Raw -Encoding UTF8
            $html | Should -Not -Match '<script>'
            $html | Should -Match '&lt;script&gt;'
            $html | Should -Match 'prefers-color-scheme'
            $html | Should -Match 'Últimas 15 actualizaciones instaladas'
            $html | Should -Match 'demo 01'
            $html | Should -Match 'demo 15'
            $html | Should -Not -Match 'demo 16'
            $html | Should -Match 'KB5009999'

            $json = Get-Content -LiteralPath $result.Json -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.Resumen.Alta | Should -Be 1
            $json.Hallazgos[0].Comprobacion | Should -Be '<script>alert(1)</script>'
            $json.Pendientes[0].KB | Should -Be 'KB5009999'
        }
    }
}

Describe 'Test-LastPatch no cuenta las firmas de Defender' {
    It 'ignora KB2267602 y toma la última acumulativa' {
        $ahora = [datetime]'2026-11-15'
        $historial = @(
            [pscustomobject]@{ Fecha = [datetime]'2026-11-14'; Titulo = 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.441.1.0)'; KB = 'KB2267602'; Resultado = 'Correcto'; Categoria = 'Seguridad' }
            [pscustomobject]@{ Fecha = [datetime]'2026-08-20'; Titulo = '2026-08 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5099999)'; KB = 'KB5099999'; Resultado = 'Correcto'; Categoria = 'Seguridad' }
        )
        $r = Test-LastPatch -History $historial -Now $ahora -WarnDays 35 -AlertDays 60
        $r.Estado | Should -Be 'Alta'
        $r.Valor | Should -Match 'KB5099999'
    }
}
