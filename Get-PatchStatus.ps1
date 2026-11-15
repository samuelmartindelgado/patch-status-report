#Requires -Version 5.1
<#
.SYNOPSIS
    Informe del estado de parches de Windows (solo lectura).
.DESCRIPTION
    Comprueba cuándo se parcheó el equipo por última vez, qué actualizaciones
    están pendientes, si hay un reinicio pendiente y si la configuración de
    Windows Update permite recibir parches. Nunca instala, descarga ni
    reinicia nada. Escribe un JSON y un HTML si se indica -OutputPath.
.PARAMETER WarnDays
    Días sin parchear a partir de los cuales se muestra un aviso. Por defecto 35.
.PARAMETER AlertDays
    Días sin parchear a partir de los cuales se muestra una alerta. Por defecto 60.
.PARAMETER SkipOnlineSearch
    No consulta Windows Update en línea; revisa solo la información local.
.PARAMETER OutputPath
    Carpeta donde se escriben patch-status.json y report.html.
.EXAMPLE
    ./Get-PatchStatus.ps1
.EXAMPLE
    ./Get-PatchStatus.ps1 -SkipOnlineSearch -OutputPath ./salida
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$WarnDays = 35,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$AlertDays = 60,

    [Parameter()]
    [switch]$SkipOnlineSearch,

    [Parameter()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'lib/PatchStatusReport.psm1'
Import-Module -Name $modulePath -Force

$notes = New-Object System.Collections.Generic.List[string]
$findings = New-Object System.Collections.Generic.List[object]

$history = @()
try {
    $history = @(Get-InstalledUpdateHistory -MaxEntries 500)
} catch {
    $notes.Add("No se pudo leer el historial de actualizaciones: $($_.Exception.Message)")
    $history = @()
}
if ($history.Count -eq 0) {
    $notes.Add('El historial de actualizaciones está vacío o no se pudo leer; el estado del último parche puede ser incompleto.')
}

$pending = @()
if ($SkipOnlineSearch) {
    $notes.Add('Búsqueda en Windows Update omitida (-SkipOnlineSearch): no se consultan actualizaciones pendientes en línea.')
} else {
    try {
        $pending = @(Get-PendingUpdates)
    } catch {
        $notes.Add("No se pudo consultar Windows Update: $($_.Exception.Message)")
        $pending = @()
    }
    if ($pending.Count -eq 0) {
        $notes.Add('Windows Update no devolvió actualizaciones pendientes (o el servicio no está disponible).')
    }
}

$findings.Add((Test-LastPatch -History $history -WarnDays $WarnDays -AlertDays $AlertDays))
$findings.Add((Test-FailedUpdates -History $history))

if ($SkipOnlineSearch) {
    $findings.Add([pscustomobject]@{
        Comprobacion = 'Actualizaciones pendientes'
        Estado       = 'OK'
        Detalle      = 'Búsqueda en línea omitida (-SkipOnlineSearch); no se puede confirmar si hay parches pendientes.'
        Valor        = 'No consultado'
        Recomendado  = 'Ejecutar sin -SkipOnlineSearch para comprobar Windows Update'
        Solucion     = ''
    })
} else {
    $findings.Add((Test-PendingUpdates -Pending $pending))
}

$findings.Add((Test-PendingReboot))
$findings.Add((Test-UpdatePolicy))
$findings.Add((Test-UpdateService))
$findings.Add((Get-Uptime))

$okCount = @($findings | Where-Object { $_.Estado -eq 'OK' }).Count
$avisoCount = @($findings | Where-Object { $_.Estado -eq 'Aviso' }).Count
$altaCount = @($findings | Where-Object { $_.Estado -eq 'Alta' }).Count

$avisoLabel = 'avisos'
if ($avisoCount -eq 1) {
    $avisoLabel = 'aviso'
}
$altaLabel = 'altas'
if ($altaCount -eq 1) {
    $altaLabel = 'alta'
}

$reportPaths = $null
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $reportPaths = Export-PatchStatusReport -Findings $findings.ToArray() -History $history -Pending $pending -OutputPath $OutputPath -Notes $notes.ToArray() -WarnDays $WarnDays -AlertDays $AlertDays
}

Write-Host ''
Write-Host ('Estado de parches - {0} - {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Write-Host ('Umbrales: aviso a los {0} días, alerta a los {1} días' -f $WarnDays, $AlertDays)
Write-Host ''

foreach ($finding in $findings) {
    $color = 'Green'
    if ($finding.Estado -eq 'Aviso') {
        $color = 'Yellow'
    } elseif ($finding.Estado -eq 'Alta') {
        $color = 'Red'
    }

    Write-Host ('[{0}] {1}' -f $finding.Estado, $finding.Comprobacion) -ForegroundColor $color
    Write-Host ('       {0}' -f $finding.Detalle)
    if (-not [string]::IsNullOrWhiteSpace([string]$finding.Valor)) {
        Write-Host ('       Valor: {0}' -f $finding.Valor)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$finding.Recomendado)) {
        Write-Host ('       Recomendado: {0}' -f $finding.Recomendado)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$finding.Solucion)) {
        Write-Host ('       Solución (ejemplo, no ejecutada): {0}' -f $finding.Solucion)
    }
}

if ($notes.Count -gt 0) {
    Write-Host ''
    Write-Host 'Notas:'
    foreach ($note in $notes) {
        Write-Host ('  - {0}' -f $note)
    }
}

Write-Host ''
Write-Host ('Resumen: {0} OK, {1} {2}, {3} {4}' -f $okCount, $avisoCount, $avisoLabel, $altaCount, $altaLabel)
if ($null -ne $reportPaths) {
    Write-Host ('Informe JSON: {0}' -f $reportPaths.Json)
    Write-Host ('Informe HTML: {0}' -f $reportPaths.Html)
}
Write-Host 'Solo lectura: no se ha instalado, descargado ni reiniciado nada.'

if ($altaCount -gt 0) {
    exit 2
}
if ($avisoCount -gt 0) {
    exit 1
}
exit 0
