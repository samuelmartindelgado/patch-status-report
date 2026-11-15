# Módulo de informe del estado de parches de Windows.
# Solo lectura: ninguna función instala, descarga ni reinicia nada.

function ConvertTo-SafeBool {
    <#
    .SYNOPSIS
        Convierte un valor leído del sistema en un booleano.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim()
    if ($text -eq '' -or $text -eq '0' -or $text -eq 'False' -or $text -eq 'false') {
        return $false
    }
    if ($text -eq '1' -or $text -eq 'True' -or $text -eq 'true') {
        return $true
    }
    return $false
}

function ConvertTo-UpdateResultText {
    <#
    .SYNOPSIS
        Traduce el ResultCode del historial de Windows Update.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$Code
    )

    switch ($Code) {
        2 { return 'Correcto' }
        3 { return 'Con errores' }
        4 { return 'Fallido' }
        5 { return 'Cancelado' }
    }

    return "Desconocido ($Code)"
}

function Get-UpdateCategory {
    <#
    .SYNOPSIS
        Clasifica una actualización como de seguridad o no según su título.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Titulo = ''
    )

    # Las firmas de Defender (KB2267602 a diario, KB915597...) y la herramienta de
    # eliminación de software malintencionado (KB890830) llevan "seguridad" en el
    # título pero NO son parches del sistema: si contaran, un equipo sin parchear
    # desde hace meses parecería al día.
    if ($Titulo -match '(?i)KB2267602|KB915597|KB2461484|KB890830|KB4052623|security intelligence|inteligencia de seguridad|definition update|actualización de definiciones|antimalware|malicious software removal|software malintencionado|defender') {
        return 'Definiciones'
    }
    if ($Titulo -match '(?i)security|seguridad|cumulative|acumulativa') {
        return 'Seguridad'
    }
    return 'Otra'
}

function ConvertTo-HistoryEntry {
    <#
    .SYNOPSIS
        Normaliza una fila del historial de actualizaciones.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Entry
    )

    $data = $Entry
    if ($data -is [System.Collections.IDictionary]) {
        $data = [pscustomobject]$data
    }

    $title = [string]$data.Titulo
    $kb = [string]$data.KB
    if ([string]::IsNullOrWhiteSpace($kb)) {
        $kbMatch = [regex]::Match($title, 'KB\d+')
        if ($kbMatch.Success) {
            $kb = $kbMatch.Value
        }
    }

    $resultText = ''
    if ($null -ne $data.Resultado) {
        $resultText = [string]$data.Resultado
    }

    $codeText = ''
    if ($null -ne $data.ResultCode) {
        $codeText = [string]$data.ResultCode
    } elseif ($resultText -match '^\d+$') {
        $codeText = $resultText
    }
    if (-not [string]::IsNullOrWhiteSpace($codeText)) {
        $code = 0
        if ([int]::TryParse($codeText, [ref]$code)) {
            $resultText = ConvertTo-UpdateResultText -Code $code
        }
    }
    if ([string]::IsNullOrWhiteSpace($resultText)) {
        $resultText = 'Desconocido'
    }

    $date = $null
    if ($null -ne $data.Fecha) {
        try {
            $date = [datetime]$data.Fecha
        } catch {
            Write-Verbose "Fecha no válida en el historial: $($_.Exception.Message)"
            $date = $null
        }
    }

    $category = [string]$data.Categoria
    if ([string]::IsNullOrWhiteSpace($category)) {
        $category = Get-UpdateCategory -Titulo $title
    }

    return [pscustomobject]@{
        Fecha     = $date
        Titulo    = $title
        KB        = $kb
        Resultado = $resultText
        Categoria = $category
    }
}

function Format-DaysText {
    <#
    .SYNOPSIS
        Da formato legible a una cantidad de días transcurridos.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double]$Days
    )

    $value = [int][math]::Round($Days)
    if ($value -le 0) {
        return 'hoy'
    }
    if ($value -eq 1) {
        return 'hace 1 día'
    }
    return "hace $value días"
}

function Get-InstalledUpdateHistory {
    <#
    .SYNOPSIS
        Devuelve el historial de actualizaciones instaladas.
    .DESCRIPTION
        Usa el objeto COM Microsoft.Update.Session y QueryHistory(0, n), con
        n = GetTotalHistoryCount limitado a 500. Si COM falla, usa Get-HotFix.
        Solo lee; no instala ni descarga nada. Admite -InputObject con datos
        simulados para probar la lógica sin tocar el equipo.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()]
        [ValidateRange(1, 500)]
        [int]$MaxEntries = 500,

        [Parameter()]
        [object[]]$InputObject
    )

    if ($PSBoundParameters.ContainsKey('InputObject')) {
        $simulated = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $entry = ConvertTo-HistoryEntry -Entry $item
            if ($null -ne $entry) {
                [void]$simulated.Add($entry)
            }
        }
        return @($simulated | Sort-Object -Property Fecha -Descending)
    }

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $total = [int]$searcher.GetTotalHistoryCount()
        if ($total -le 0) {
            return @()
        }

        $count = [math]::Min($total, $MaxEntries)
        $history = $searcher.QueryHistory(0, $count)
        $entries = New-Object System.Collections.Generic.List[object]

        foreach ($item in $history) {
            $title = [string]$item.Title
            $kb = ''
            $kbMatch = [regex]::Match($title, 'KB\d+')
            if ($kbMatch.Success) {
                $kb = $kbMatch.Value
            }

            [void]$entries.Add([pscustomobject]@{
                Fecha     = [datetime]$item.Date
                Titulo    = $title
                KB        = $kb
                Resultado = ConvertTo-UpdateResultText -Code ([int]$item.ResultCode)
                Categoria = Get-UpdateCategory -Titulo $title
            })
        }

        return @($entries | Sort-Object -Property Fecha -Descending)
    } catch {
        Write-Verbose "No se pudo consultar el historial por COM: $($_.Exception.Message)"
    }

    try {
        $hotfixes = Get-HotFix -ErrorAction Stop
        $fallback = New-Object System.Collections.Generic.List[object]
        foreach ($hotfix in $hotfixes) {
            $installedOn = $null
            if ($null -ne $hotfix.InstalledOn) {
                $installedOn = [datetime]$hotfix.InstalledOn
            }
            [void]$fallback.Add([pscustomobject]@{
                Fecha     = $installedOn
                Titulo    = "Actualización $([string]$hotfix.HotFixID)"
                KB        = [string]$hotfix.HotFixID
                Resultado = 'Correcto'
                Categoria = 'Seguridad'
            })
        }
        return @($fallback | Sort-Object -Property Fecha -Descending)
    } catch {
        Write-Verbose "Tampoco se pudo usar Get-HotFix: $($_.Exception.Message)"
        return @()
    }
}

function Test-LastPatch {
    <#
    .SYNOPSIS
        Comprueba cuándo se instaló la última actualización de seguridad.
    .DESCRIPTION
        Lógica pura: recibe el historial ya leído y calcula los días desde la
        última actualización acumulativa o de seguridad instalada correctamente.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$History = @(),

        [Parameter()]
        [datetime]$Now = (Get-Date),

        [Parameter()]
        [ValidateRange(1, 3650)]
        [int]$WarnDays = 35,

        [Parameter()]
        [ValidateRange(1, 3650)]
        [int]$AlertDays = 60
    )

    $lastDate = $null
    $lastKb = ''

    foreach ($raw in $History) {
        $entry = ConvertTo-HistoryEntry -Entry $raw
        if ($null -eq $entry) {
            continue
        }
        if ($entry.Resultado -ne 'Correcto') {
            continue
        }
        if ($null -eq $entry.Fecha) {
            continue
        }

        # Se recalcula por el título (aunque venga clasificado) para descartar firmas
        # de Defender; las entradas de Get-HotFix vienen ya como 'Seguridad'.
        $categoriaTitulo = Get-UpdateCategory -Titulo ([string]$entry.Titulo)
        $isSecurity = ($categoriaTitulo -eq 'Seguridad') -or
            ($entry.Categoria -eq 'Seguridad' -and $categoriaTitulo -ne 'Definiciones')
        if (-not $isSecurity) {
            continue
        }

        if ($null -eq $lastDate -or $entry.Fecha -gt $lastDate) {
            $lastDate = $entry.Fecha
            $lastKb = $entry.KB
        }
    }

    if ($null -eq $lastDate) {
        return [pscustomobject]@{
            Comprobacion = 'Último parche'
            Estado       = 'Alta'
            Detalle      = 'No hay ninguna actualización acumulativa o de seguridad instalada correctamente en el historial.'
            Valor        = 'Ninguna'
            Recomendado  = 'Aplicar la última actualización acumulativa disponible'
            Solucion     = 'Instalar las actualizaciones desde Windows Update o WSUS (ejemplo, no ejecutado).'
        }
    }

    $days = ($Now - $lastDate).TotalDays
    if ($days -lt 0) {
        $days = 0
    }
    $daysText = Format-DaysText -Days $days

    $kbText = ''
    if (-not [string]::IsNullOrWhiteSpace($lastKb)) {
        $kbText = " ($lastKb)"
    }

    $valor = "$($lastDate.ToString('yyyy-MM-dd'))$kbText - $daysText"

    if ($days -gt $AlertDays) {
        $detalle = "Han pasado $([int][math]::Round($days)) días desde la última actualización acumulativa o de seguridad$kbText; supera el umbral de alerta de $AlertDays días."
        $estado = 'Alta'
        $recomendado = 'Aplicar las actualizaciones acumulativas pendientes cuanto antes'
    } elseif ($days -gt $WarnDays) {
        $detalle = "Han pasado $([int][math]::Round($days)) días desde la última actualización acumulativa o de seguridad$kbText; se recomienda parchear cada $WarnDays días."
        $estado = 'Aviso'
        $recomendado = 'Revisar y aplicar las actualizaciones pendientes'
    } else {
        $detalle = "La última actualización acumulativa o de seguridad se instaló $daysText."
        $estado = 'OK'
        $recomendado = 'Mantener el ritmo de parcheo mensual'
    }

    $solucion = ''
    if ($estado -ne 'OK') {
        $solucion = 'Abrir Configuración > Windows Update y aplicar las actualizaciones (ejemplo, no ejecutado).'
    }

    return [pscustomobject]@{
        Comprobacion = 'Último parche'
        Estado       = $estado
        Detalle      = $detalle
        Valor        = $valor
        Recomendado  = $recomendado
        Solucion     = $solucion
    }
}

function Test-FailedUpdates {
    <#
    .SYNOPSIS
        Busca actualizaciones fallidas que no se volvieron a instalar.
    .DESCRIPTION
        Lógica pura: revisa los últimos 30 días del historial y avisa de las
        actualizaciones con resultado Fallido o Con errores que no tengan una
        instalación correcta posterior del mismo KB.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$History = @(),

        [Parameter()]
        [datetime]$Now = (Get-Date),

        [Parameter()]
        [ValidateRange(1, 365)]
        [int]$Days = 30
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $History) {
        $entry = ConvertTo-HistoryEntry -Entry $raw
        if ($null -ne $entry -and $null -ne $entry.Fecha) {
            [void]$entries.Add($entry)
        }
    }

    $failedKeys = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        if ($entry.Resultado -ne 'Fallido' -and $entry.Resultado -ne 'Con errores') {
            continue
        }
        if (($Now - $entry.Fecha).TotalDays -gt $Days) {
            continue
        }

        $reinstalled = $false
        foreach ($other in $entries) {
            if ($other.Resultado -ne 'Correcto') {
                continue
            }
            if ($other.Fecha -le $entry.Fecha) {
                continue
            }
            $sameKb = (-not [string]::IsNullOrWhiteSpace($entry.KB)) -and ($other.KB -eq $entry.KB)
            $sameTitle = (-not [string]::IsNullOrWhiteSpace($entry.Titulo)) -and ($other.Titulo -eq $entry.Titulo)
            if ($sameKb -or $sameTitle) {
                $reinstalled = $true
                break
            }
        }

        if ($reinstalled) {
            continue
        }

        $key = $entry.KB
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = $entry.Titulo
        }
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = 'sin identificar'
        }
        if (-not $failedKeys.Contains($key)) {
            [void]$failedKeys.Add($key)
        }
    }

    if ($failedKeys.Count -gt 0) {
        return [pscustomobject]@{
            Comprobacion = 'Actualizaciones fallidas'
            Estado       = 'Aviso'
            Detalle      = "Hay $($failedKeys.Count) actualización(es) fallida(s) en los últimos $Days días que no se volvieron a instalar correctamente."
            Valor        = ($failedKeys -join ', ')
            Recomendado  = 'Revisar el código de error y reinstalar esas actualizaciones'
            Solucion     = 'Consultar el historial de Windows Update y reinstalar las KB indicadas (ejemplo, no ejecutado).'
        }
    }

    return [pscustomobject]@{
        Comprobacion = 'Actualizaciones fallidas'
        Estado       = 'OK'
        Detalle      = "No hay actualizaciones fallidas sin resolver en los últimos $Days días."
        Valor        = 'Ninguna'
        Recomendado  = ''
        Solucion     = ''
    }
}

function ConvertTo-PendingEntry {
    <#
    .SYNOPSIS
        Normaliza una actualización pendiente.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Entry
    )

    $data = $Entry
    if ($data -is [System.Collections.IDictionary]) {
        $data = [pscustomobject]$data
    }

    $title = [string]$data.Titulo
    $kb = [string]$data.KB
    if ([string]::IsNullOrWhiteSpace($kb)) {
        $kbMatch = [regex]::Match($title, 'KB\d+')
        if ($kbMatch.Success) {
            $kb = $kbMatch.Value
        }
    }

    $severity = ''
    if ($null -ne $data.Severidad) {
        $severity = [string]$data.Severidad
    } elseif ($null -ne $data.MsrcSeverity) {
        $severity = [string]$data.MsrcSeverity
    }

    $sizeMB = 0
    if ($null -ne $data.TamanoMB) {
        $sizeMB = [math]::Round([double]$data.TamanoMB, 1)
    } elseif ($null -ne $data.MaxDownloadSize) {
        $sizeMB = [math]::Round(([double]$data.MaxDownloadSize) / 1MB, 1)
    }

    $mandatory = $false
    if ($null -ne $data.Obligatoria) {
        $mandatory = ConvertTo-SafeBool -Value $data.Obligatoria
    } elseif ($null -ne $data.IsMandatory) {
        $mandatory = ConvertTo-SafeBool -Value $data.IsMandatory
    }

    return [pscustomobject]@{
        Titulo      = $title
        KB          = $kb
        Severidad   = $severity
        TamanoMB    = $sizeMB
        Obligatoria = $mandatory
    }
}

function Get-PendingUpdates {
    <#
    .SYNOPSIS
        Consulta las actualizaciones pendientes en Windows Update.
    .DESCRIPTION
        Usa Microsoft.Update.Session con la búsqueda
        "IsInstalled=0 and IsHidden=0 and Type='Software'". Puede tardar y
        requiere acceso a Windows Update; cualquier error se captura y se
        devuelve una lista vacía. Es solo lectura: no descarga ni instala nada.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()]
        [object[]]$InputObject,

        [Parameter()]
        [switch]$SkipOnlineSearch
    )

    if ($SkipOnlineSearch) {
        return @()
    }

    if ($PSBoundParameters.ContainsKey('InputObject')) {
        $simulated = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $entry = ConvertTo-PendingEntry -Entry $item
            if ($null -ne $entry) {
                [void]$simulated.Add($entry)
            }
        }
        return $simulated.ToArray()
    }

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

        $updates = New-Object System.Collections.Generic.List[object]
        foreach ($update in $searchResult.Updates) {
            $sizeMB = 0
            try {
                $sizeMB = [math]::Round(([double]$update.MaxDownloadSize) / 1MB, 1)
            } catch {
                Write-Verbose "Tamaño desconocido: $($_.Exception.Message)"
                $sizeMB = 0
            }

            $kbList = @()
            try {
                $kbList = @($update.KBArticleIDs)
            } catch {
                Write-Verbose "KB desconocida: $($_.Exception.Message)"
                $kbList = @()
            }
            $kbText = (@($kbList | ForEach-Object { 'KB' + [string]$_ }) -join ', ')

            [void]$updates.Add([pscustomobject]@{
                Titulo      = [string]$update.Title
                KB          = $kbText
                Severidad   = [string]$update.MsrcSeverity
                TamanoMB    = $sizeMB
                Obligatoria = [bool]$update.IsMandatory
            })
        }

        return $updates.ToArray()
    } catch {
        Write-Verbose "No se pudo consultar Windows Update: $($_.Exception.Message)"
        return @()
    }
}

function Test-PendingUpdates {
    <#
    .SYNOPSIS
        Evalúa las actualizaciones pendientes.
    .DESCRIPTION
        Lógica pura: Alta si alguna pendiente es crítica, Aviso si hay alguna
        de seguridad u otras, OK si no hay ninguna.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Pending = @()
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $Pending) {
        $entry = ConvertTo-PendingEntry -Entry $raw
        if ($null -ne $entry) {
            [void]$entries.Add($entry)
        }
    }

    if ($entries.Count -eq 0) {
        return [pscustomobject]@{
            Comprobacion = 'Actualizaciones pendientes'
            Estado       = 'OK'
            Detalle      = 'No hay actualizaciones pendientes de instalar.'
            Valor        = 'Ninguna'
            Recomendado  = ''
            Solucion     = ''
        }
    }

    $critical = New-Object System.Collections.Generic.List[string]
    $important = New-Object System.Collections.Generic.List[string]
    $others = New-Object System.Collections.Generic.List[string]
    $kbList = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        $severity = [string]$entry.Severidad
        if ($severity -match '(?i)^critical|^cr[ií]tica') {
            if (-not [string]::IsNullOrWhiteSpace($entry.KB)) {
                [void]$critical.Add($entry.KB)
            } else {
                [void]$critical.Add($entry.Titulo)
            }
        } elseif ($severity -match '(?i)^important|^importante') {
            if (-not [string]::IsNullOrWhiteSpace($entry.KB)) {
                [void]$important.Add($entry.KB)
            } else {
                [void]$important.Add($entry.Titulo)
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($entry.KB)) {
            [void]$others.Add($entry.KB)
        }

        if (-not [string]::IsNullOrWhiteSpace($entry.KB)) {
            [void]$kbList.Add($entry.KB)
        }
    }

    $valor = "$($entries.Count) pendiente(s)"
    if ($kbList.Count -gt 0) {
        $valor = "${valor}: $($kbList -join ', ')"
    }

    if ($critical.Count -gt 0) {
        return [pscustomobject]@{
            Comprobacion = 'Actualizaciones pendientes'
            Estado       = 'Alta'
            Detalle      = "Hay $($critical.Count) actualización(es) pendiente(s) marcadas como críticas por Microsoft."
            Valor        = "Críticas: $($critical -join ', ')"
            Recomendado  = 'Instalar las actualizaciones críticas cuanto antes'
            Solucion     = 'Aplicar las actualizaciones desde Windows Update o WSUS (ejemplo, no ejecutado).'
        }
    }

    $detalle = "Hay $($entries.Count) actualización(es) pendiente(s) de instalar."
    if ($important.Count -gt 0) {
        $detalle = "Hay $($entries.Count) actualización(es) pendiente(s), $($important.Count) de ellas de seguridad (Important)."
        $recomendado = 'Instalar las actualizaciones de seguridad pendientes'
    } else {
        $recomendado = 'Revisar y programar las actualizaciones pendientes'
    }

    return [pscustomobject]@{
        Comprobacion = 'Actualizaciones pendientes'
        Estado       = 'Aviso'
        Detalle      = $detalle
        Valor        = $valor
        Recomendado  = $recomendado
        Solucion     = 'Aplicar las actualizaciones desde Windows Update o WSUS (ejemplo, no ejecutado).'
    }
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Comprueba si hay un reinicio pendiente.
    .DESCRIPTION
        Lee, solo lectura, las claves CBS RebootPending, WindowsUpdate
        RebootRequired y el valor PendingFileRenameOperations. Admite
        -InputObject con datos simulados para probar la lógica.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [object]$InputObject
    )

    $cbsPending = $false
    $wuPending = $false
    $renamePending = $false
    $note = ''

    if ($PSBoundParameters.ContainsKey('InputObject') -and $null -ne $InputObject) {
        $data = $InputObject
        if ($data -is [System.Collections.IDictionary]) {
            $data = [pscustomobject]$data
        }
        if ($null -ne $data.CbsRebootPending) {
            $cbsPending = ConvertTo-SafeBool -Value $data.CbsRebootPending
        }
        if ($null -ne $data.WindowsUpdateRebootRequired) {
            $wuPending = ConvertTo-SafeBool -Value $data.WindowsUpdateRebootRequired
        }
        if ($null -ne $data.PendingFileRenameOperations) {
            $renamePending = @($data.PendingFileRenameOperations).Count -gt 0
        }
    } else {
        $cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wuPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $sessionPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

        try {
            $cbsPending = Test-Path -LiteralPath $cbsPath
        } catch {
            $note = "$note No se pudo leer Component Based Servicing: $($_.Exception.Message)"
        }

        try {
            $wuPending = Test-Path -LiteralPath $wuPath
        } catch {
            $note = "$note No se pudo leer Windows Update: $($_.Exception.Message)"
        }

        try {
            $renameValue = (Get-ItemProperty -LiteralPath $sessionPath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
            $renamePending = @($renameValue).Count -gt 0
        } catch {
            $note = "$note No se pudo leer PendingFileRenameOperations: $($_.Exception.Message)"
        }
    }

    $keys = New-Object System.Collections.Generic.List[string]
    if ($cbsPending) {
        [void]$keys.Add('CBS RebootPending')
    }
    if ($wuPending) {
        [void]$keys.Add('WindowsUpdate RebootRequired')
    }
    if ($renamePending) {
        [void]$keys.Add('PendingFileRenameOperations')
    }

    $valor = 'Sin reinicio pendiente'
    if ($keys.Count -gt 0) {
        $valor = ($keys -join ', ')
    }

    if ($keys.Count -gt 0) {
        $detalle = 'El equipo tiene un reinicio pendiente para terminar de aplicar cambios.'
        if (-not [string]::IsNullOrWhiteSpace($note)) {
            $detalle = "$detalle $note"
        }
        return [pscustomobject]@{
            Comprobacion = 'Reinicio pendiente'
            Estado       = 'Aviso'
            Detalle      = $detalle
            Valor        = $valor
            Recomendado  = 'Reiniciar el equipo fuera del horario de trabajo'
            Solucion     = 'Programar un reinicio controlado (ejemplo, no ejecutado).'
        }
    }

    $detalle = 'No hay claves que indiquen un reinicio pendiente.'
    if (-not [string]::IsNullOrWhiteSpace($note)) {
        $detalle = "$detalle $note"
    }

    return [pscustomobject]@{
        Comprobacion = 'Reinicio pendiente'
        Estado       = 'OK'
        Detalle      = $detalle
        Valor        = $valor
        Recomendado  = ''
        Solucion     = ''
    }
}

function Test-UpdatePolicy {
    <#
    .SYNOPSIS
        Revisa la directiva de Windows Update.
    .DESCRIPTION
        Lee NoAutoUpdate, AUOptions y WUServer (WSUS). Alta si las
        actualizaciones automáticas están desactivadas por directiva. Admite
        -InputObject con datos simulados para probar la lógica.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [object]$InputObject
    )

    $noAutoUpdate = $null
    $auOptions = $null
    $wuServer = ''
    $note = ''

    if ($PSBoundParameters.ContainsKey('InputObject') -and $null -ne $InputObject) {
        $data = $InputObject
        if ($data -is [System.Collections.IDictionary]) {
            $data = [pscustomobject]$data
        }
        if ($null -ne $data.NoAutoUpdate) {
            $noAutoUpdate = $data.NoAutoUpdate
        }
        if ($null -ne $data.AUOptions) {
            $auOptions = $data.AUOptions
        }
        if ($null -ne $data.WUServer) {
            $wuServer = [string]$data.WUServer
        }
    } else {
        $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

        try {
            if (Test-Path -LiteralPath $auPath) {
                $auPolicy = Get-ItemProperty -LiteralPath $auPath -ErrorAction Stop
                if ($null -ne $auPolicy.NoAutoUpdate) {
                    $noAutoUpdate = $auPolicy.NoAutoUpdate
                }
                if ($null -ne $auPolicy.AUOptions) {
                    $auOptions = $auPolicy.AUOptions
                }
            }
        } catch {
            $note = "No se pudo leer la directiva AU: $($_.Exception.Message)"
        }

        try {
            if (Test-Path -LiteralPath $wuPath) {
                $wuPolicy = Get-ItemProperty -LiteralPath $wuPath -ErrorAction Stop
                if ($null -ne $wuPolicy.WUServer) {
                    $wuServer = [string]$wuPolicy.WUServer
                }
            }
        } catch {
            $note = "$note No se pudo leer la directiva de Windows Update: $($_.Exception.Message)"
        }
    }

    $isDisabled = ConvertTo-SafeBool -Value $noAutoUpdate
    $wsusText = ''
    if (-not [string]::IsNullOrWhiteSpace($wuServer)) {
        $wsusText = " Las actualizaciones se gestionan por WSUS ($wuServer)."
    }

    $optionsText = ''
    if ($null -ne $auOptions) {
        $optionsText = " AUOptions = $([string]$auOptions)."
    }

    if ($isDisabled) {
        $detalle = "Las actualizaciones automáticas están desactivadas por directiva.$optionsText$wsusText"
        if (-not [string]::IsNullOrWhiteSpace($note)) {
            $detalle = "$detalle $note"
        }
        return [pscustomobject]@{
            Comprobacion = 'Directiva de actualizaciones'
            Estado       = 'Alta'
            Detalle      = $detalle.Trim()
            Valor        = 'NoAutoUpdate = 1 (desactivadas)'
            Recomendado  = 'Permitir las actualizaciones automáticas o gestionarlas por WSUS'
            Solucion     = 'Revisar la GPO de Windows Update y poner NoAutoUpdate = 0 (ejemplo, no ejecutado).'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($wsusText)) {
        $detalle = "No hay directiva que desactive las actualizaciones.$optionsText$wsusText"
        $valor = 'Gestionado por WSUS'
        $recomendado = 'Comprobar que el servidor WSUS sigue sincronizando'
    } else {
        $detalle = "No hay directiva que desactive las actualizaciones automáticas.$optionsText"
        $valor = 'Sin directiva restrictiva'
        $recomendado = ''
    }

    if (-not [string]::IsNullOrWhiteSpace($note)) {
        $detalle = "$detalle $note"
    }

    return [pscustomobject]@{
        Comprobacion = 'Directiva de actualizaciones'
        Estado       = 'OK'
        Detalle      = $detalle.Trim()
        Valor        = $valor
        Recomendado  = $recomendado
        Solucion     = ''
    }
}

function Test-UpdateService {
    <#
    .SYNOPSIS
        Comprueba el estado del servicio wuauserv.
    .DESCRIPTION
        Alta si el servicio Windows Update está deshabilitado. Admite
        -InputObject con StartType o Disabled para probar la lógica.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [object]$InputObject
    )

    $startType = ''
    $note = ''

    if ($PSBoundParameters.ContainsKey('InputObject') -and $null -ne $InputObject) {
        $data = $InputObject
        if ($data -is [System.Collections.IDictionary]) {
            $data = [pscustomobject]$data
        }
        if ($null -ne $data.StartType) {
            $startType = [string]$data.StartType
        } elseif ($null -ne $data.Disabled) {
            if (ConvertTo-SafeBool -Value $data.Disabled) {
                $startType = 'Disabled'
            } else {
                $startType = 'Manual'
            }
        }
    } else {
        try {
            $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
            if ($null -ne $service.StartType) {
                $startType = [string]$service.StartType
            }
        } catch {
            $note = "No se pudo consultar el servicio wuauserv: $($_.Exception.Message)"
        }

        if ([string]::IsNullOrWhiteSpace($startType)) {
            try {
                $serviceKey = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' -Name 'Start' -ErrorAction Stop
                $startValue = [int]$serviceKey.Start
                if ($startValue -eq 4) {
                    $startType = 'Disabled'
                } elseif ($startValue -eq 2) {
                    $startType = 'Automatic'
                } else {
                    $startType = 'Manual'
                }
            } catch {
                $note = "$note No se pudo leer el registro del servicio: $($_.Exception.Message)"
            }
        }
    }

    if ($startType -eq 'Disabled') {
        $detalle = 'El servicio Windows Update (wuauserv) está deshabilitado; el equipo no recibirá parches.'
        if (-not [string]::IsNullOrWhiteSpace($note)) {
            $detalle = "$detalle $note"
        }
        return [pscustomobject]@{
            Comprobacion = 'Servicio Windows Update'
            Estado       = 'Alta'
            Detalle      = $detalle
            Valor        = 'wuauserv: Disabled'
            Recomendado  = 'Habilitar el servicio wuauserv'
            Solucion     = 'Set-Service -Name wuauserv -StartupType Manual (ejemplo, no ejecutado).'
        }
    }

    $valor = 'wuauserv: desconocido'
    if (-not [string]::IsNullOrWhiteSpace($startType)) {
        $valor = "wuauserv: $startType"
    }

    $detalle = 'El servicio Windows Update no está deshabilitado.'
    if (-not [string]::IsNullOrWhiteSpace($note)) {
        $detalle = "$detalle $note"
    }

    return [pscustomobject]@{
        Comprobacion = 'Servicio Windows Update'
        Estado       = 'OK'
        Detalle      = $detalle
        Valor        = $valor
        Recomendado  = ''
        Solucion     = ''
    }
}

function Get-Uptime {
    <#
    .SYNOPSIS
        Calcula los días transcurridos desde el último arranque.
    .DESCRIPTION
        Lee LastBootUpTime de Win32_OperatingSystem. Aviso si el equipo lleva
        más de 30 días encendido, porque los parches del kernel no se aplican
        hasta reiniciar. Admite -InputObject (fecha u objeto con
        LastBootUpTime) para probar la lógica.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'El nombre Get-Uptime viene fijado por el encargo del proyecto.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [object]$InputObject,

        [Parameter()]
        [datetime]$Now = (Get-Date)
    )

    $lastBoot = $null
    $note = ''

    if ($PSBoundParameters.ContainsKey('InputObject') -and $null -ne $InputObject) {
        if ($InputObject -is [datetime]) {
            $lastBoot = [datetime]$InputObject
        } else {
            $data = $InputObject
            if ($data -is [System.Collections.IDictionary]) {
                $data = [pscustomobject]$data
            }
            if ($null -ne $data.LastBootUpTime) {
                $lastBoot = [datetime]$data.LastBootUpTime
            }
        }
    } else {
        try {
            $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
            if ($null -ne $os.LastBootUpTime) {
                $lastBoot = [datetime]$os.LastBootUpTime
            }
        } catch {
            $note = "No se pudo leer el último arranque: $($_.Exception.Message)"
        }
    }

    if ($null -eq $lastBoot) {
        $detalle = 'No se pudo determinar la fecha del último arranque.'
        if (-not [string]::IsNullOrWhiteSpace($note)) {
            $detalle = "$detalle $note"
        }
        return [pscustomobject]@{
            Comprobacion = 'Tiempo encendido'
            Estado       = 'OK'
            Detalle      = $detalle
            Valor        = 'Desconocido'
            Recomendado  = ''
            Solucion     = ''
        }
    }

    $days = ($Now - $lastBoot).TotalDays
    if ($days -lt 0) {
        $days = 0
    }

    $roundedDays = [int][math]::Round($days)
    $daysText = "$roundedDays días"
    if ($roundedDays -eq 1) {
        $daysText = '1 día'
    } elseif ($roundedDays -le 0) {
        $daysText = 'menos de 1 día'
    }

    $valor = "$daysText (último arranque $($lastBoot.ToString('yyyy-MM-dd HH:mm')))"

    if ($days -gt 30) {
        $detalle = "El equipo lleva $roundedDays días sin reiniciar; los parches del kernel no se aplican hasta reiniciar."
        $estado = 'Aviso'
        $recomendado = 'Programar un reinicio para completar la instalación de parches'
    } else {
        $detalle = "El equipo lleva $daysText encendido."
        $estado = 'OK'
        $recomendado = ''
    }

    return [pscustomobject]@{
        Comprobacion = 'Tiempo encendido'
        Estado       = $estado
        Detalle      = $detalle
        Valor        = $valor
        Recomendado  = $recomendado
        Solucion     = ''
    }
}

function ConvertTo-HtmlText {
    <#
    .SYNOPSIS
        Escapa un texto para insertarlo en HTML.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [object]$Text
    )

    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function New-PatchStatusHtml {
    <#
    .SYNOPSIS
        Construye el informe HTML autónomo.
    .DESCRIPTION
        Genera HTML con CSS en línea (sin JavaScript externo), modo oscuro por
        prefers-color-scheme, recuento por estado y tablas de las últimas 15
        actualizaciones instaladas y de las pendientes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [object[]]$Findings = @(),

        [Parameter()]
        [object[]]$History = @(),

        [Parameter()]
        [object[]]$Pending = @(),

        [Parameter()]
        [string[]]$Notes = @(),

        [Parameter()]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter()]
        [datetime]$GeneratedAt = (Get-Date),

        [Parameter()]
        [int]$WarnDays = 35,

        [Parameter()]
        [int]$AlertDays = 60
    )

    $okCount = @($Findings | Where-Object { $_.Estado -eq 'OK' }).Count
    $avisoCount = @($Findings | Where-Object { $_.Estado -eq 'Aviso' }).Count
    $altaCount = @($Findings | Where-Object { $_.Estado -eq 'Alta' }).Count

    $rows = New-Object System.Text.StringBuilder
    foreach ($finding in $Findings) {
        $cssClass = 'ok'
        if ($finding.Estado -eq 'Aviso') {
            $cssClass = 'aviso'
        } elseif ($finding.Estado -eq 'Alta') {
            $cssClass = 'alta'
        }

        [void]$rows.AppendLine('<tr class="' + $cssClass + '">')
        [void]$rows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $finding.Comprobacion) + '</td>')
        [void]$rows.AppendLine('<td><span class="pill ' + $cssClass + '">' + (ConvertTo-HtmlText -Text $finding.Estado) + '</span></td>')
        [void]$rows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $finding.Detalle) + '</td>')
        [void]$rows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $finding.Valor) + '</td>')
        [void]$rows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $finding.Recomendado) + '</td>')
        [void]$rows.AppendLine('<td class="command">' + (ConvertTo-HtmlText -Text $finding.Solucion) + '</td>')
        [void]$rows.AppendLine('</tr>')
    }

    $historyRows = New-Object System.Text.StringBuilder
    $historyCount = 0
    foreach ($entry in $History) {
        if ($historyCount -ge 15) {
            break
        }
        $dateText = ''
        if ($null -ne $entry.Fecha) {
            $dateText = ([datetime]$entry.Fecha).ToString('yyyy-MM-dd')
        }
        [void]$historyRows.AppendLine('<tr>')
        [void]$historyRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $dateText) + '</td>')
        [void]$historyRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.Titulo) + '</td>')
        [void]$historyRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.KB) + '</td>')
        [void]$historyRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.Resultado) + '</td>')
        [void]$historyRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.Categoria) + '</td>')
        [void]$historyRows.AppendLine('</tr>')
        $historyCount++
    }
    if ($historyCount -eq 0) {
        [void]$historyRows.AppendLine('<tr><td colspan="5">No se pudo leer el historial de actualizaciones.</td></tr>')
    }

    $pendingRows = New-Object System.Text.StringBuilder
    $pendingCount = 0
    foreach ($entry in $Pending) {
        $sizeText = ''
        if ($null -ne $entry.TamanoMB) {
            $sizeText = [string]$entry.TamanoMB
        }
        $mandatoryText = 'No'
        if ($null -ne $entry.Obligatoria -and [bool]$entry.Obligatoria) {
            $mandatoryText = 'Sí'
        }
        [void]$pendingRows.AppendLine('<tr>')
        [void]$pendingRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.Titulo) + '</td>')
        [void]$pendingRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.KB) + '</td>')
        [void]$pendingRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $entry.Severidad) + '</td>')
        [void]$pendingRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $sizeText) + '</td>')
        [void]$pendingRows.AppendLine('<td>' + (ConvertTo-HtmlText -Text $mandatoryText) + '</td>')
        [void]$pendingRows.AppendLine('</tr>')
        $pendingCount++
    }
    if ($pendingCount -eq 0) {
        [void]$pendingRows.AppendLine('<tr><td colspan="5">No hay actualizaciones pendientes (o no se consultó Windows Update).</td></tr>')
    }

    $notesBlock = New-Object System.Text.StringBuilder
    if ($Notes.Count -gt 0) {
        [void]$notesBlock.AppendLine('<h2>Notas</h2>')
        [void]$notesBlock.AppendLine('<ul class="notes">')
        foreach ($item in $Notes) {
            [void]$notesBlock.AppendLine('<li>' + (ConvertTo-HtmlText -Text $item) + '</li>')
        }
        [void]$notesBlock.AppendLine('</ul>')
    } else {
        [void]$notesBlock.AppendLine('<p class="notes">Sin notas.</p>')
    }

    $css = @'
:root {
    color-scheme: light dark;
    --bg: #f4f6f8;
    --panel: #ffffff;
    --text: #1a202c;
    --muted: #5b6572;
    --border: #d8dee6;
    --ok: #0f7b3f;
    --aviso: #b45309;
    --alta: #b91c1c;
    --ok-bg: #e7f6ec;
    --aviso-bg: #fef3c7;
    --alta-bg: #fee2e2;
}
@media (prefers-color-scheme: dark) {
    :root {
        --bg: #0f1419;
        --panel: #161c23;
        --text: #e6edf3;
        --muted: #9aa7b4;
        --border: #2b3541;
        --ok: #4ade80;
        --aviso: #fbbf24;
        --alta: #f87171;
        --ok-bg: #123324;
        --aviso-bg: #3a2a08;
        --alta-bg: #3b1414;
    }
}
* { box-sizing: border-box; }
body {
    margin: 0;
    padding: 24px;
    background: var(--bg);
    color: var(--text);
    font-family: "Segoe UI", Tahoma, Arial, sans-serif;
    font-size: 15px;
    line-height: 1.45;
}
main { max-width: 1200px; margin: 0 auto; }
h1 { margin: 0 0 4px; font-size: 24px; }
h2 { margin: 28px 0 8px; font-size: 18px; }
.meta { color: var(--muted); margin: 0 0 20px; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 20px; }
.card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 12px 18px;
    min-width: 120px;
}
.card .num { display: block; font-size: 26px; font-weight: 700; }
.card.ok .num { color: var(--ok); }
.card.aviso .num { color: var(--aviso); }
.card.alta .num { color: var(--alta); }
table {
    width: 100%;
    border-collapse: collapse;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    overflow: hidden;
}
th, td {
    padding: 9px 11px;
    border-bottom: 1px solid var(--border);
    text-align: left;
    vertical-align: top;
}
th { background: rgba(127, 127, 127, 0.12); font-size: 13px; text-transform: uppercase; letter-spacing: 0.03em; }
tr.alta td { background: var(--alta-bg); }
tr.aviso td { background: var(--aviso-bg); }
.pill {
    display: inline-block;
    padding: 2px 9px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 700;
}
.pill.ok { color: var(--ok); border: 1px solid var(--ok); }
.pill.aviso { color: var(--aviso); border: 1px solid var(--aviso); }
.pill.alta { color: var(--alta); border: 1px solid var(--alta); }
.command { font-family: Consolas, "Courier New", monospace; font-size: 13px; word-break: break-all; }
.notes { color: var(--muted); }
footer { margin-top: 28px; color: var(--muted); font-size: 13px; }
'@

    $template = @'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Estado de parches - __COMPUTER__</title>
<style>
__CSS__
</style>
</head>
<body>
<main>
<h1>Estado de parches de Windows</h1>
<p class="meta">Equipo: <strong>__COMPUTER__</strong> &middot; Fecha: __DATE__ &middot; Umbrales: aviso __WARN__ días, alerta __ALERT__ días</p>
<div class="cards">
<div class="card ok"><span class="num">__OK__</span><span>OK</span></div>
<div class="card aviso"><span class="num">__AVISO__</span><span>Aviso</span></div>
<div class="card alta"><span class="num">__ALTA__</span><span>Alta</span></div>
</div>
<table>
<thead>
<tr><th>Comprobación</th><th>Estado</th><th>Detalle</th><th>Valor</th><th>Recomendado</th><th>Solución (solo ejemplo)</th></tr>
</thead>
<tbody>
__ROWS__
</tbody>
</table>
<h2>Últimas 15 actualizaciones instaladas</h2>
<table>
<thead>
<tr><th>Fecha</th><th>Título</th><th>KB</th><th>Resultado</th><th>Categoría</th></tr>
</thead>
<tbody>
__HISTORY__
</tbody>
</table>
<h2>Actualizaciones pendientes</h2>
<table>
<thead>
<tr><th>Título</th><th>KB</th><th>Severidad</th><th>Tamaño (MB)</th><th>Obligatoria</th></tr>
</thead>
<tbody>
__PENDING__
</tbody>
</table>
__NOTES__
<footer>Informe generado automáticamente. Herramienta de solo lectura: no instala, descarga ni reinicia nada. Los comandos de la columna Solución son ejemplos y no se han ejecutado.</footer>
</main>
</body>
</html>
'@

    $html = $template.Replace('__CSS__', $css)
    $html = $html.Replace('__COMPUTER__', (ConvertTo-HtmlText -Text $ComputerName))
    $html = $html.Replace('__DATE__', (ConvertTo-HtmlText -Text $GeneratedAt.ToString('yyyy-MM-dd HH:mm')))
    $html = $html.Replace('__WARN__', (ConvertTo-HtmlText -Text $WarnDays))
    $html = $html.Replace('__ALERT__', (ConvertTo-HtmlText -Text $AlertDays))
    $html = $html.Replace('__OK__', (ConvertTo-HtmlText -Text $okCount))
    $html = $html.Replace('__AVISO__', (ConvertTo-HtmlText -Text $avisoCount))
    $html = $html.Replace('__ALTA__', (ConvertTo-HtmlText -Text $altaCount))
    $html = $html.Replace('__ROWS__', $rows.ToString())
    $html = $html.Replace('__HISTORY__', $historyRows.ToString())
    $html = $html.Replace('__PENDING__', $pendingRows.ToString())
    $html = $html.Replace('__NOTES__', $notesBlock.ToString())

    return $html
}

function Export-PatchStatusReport {
    <#
    .SYNOPSIS
        Escribe el informe JSON y el HTML autónomo.
    .DESCRIPTION
        Crea <OutputPath>\patch-status.json y <OutputPath>\report.html. El HTML
        lleva el CSS en línea, no usa JavaScript externo, admite modo oscuro y
        escapa todos los textos dinámicos.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Findings,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$History = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Pending = @(),

        [Parameter()]
        [string[]]$Notes = @(),

        [Parameter()]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter()]
        [datetime]$GeneratedAt = (Get-Date),

        [Parameter()]
        [int]$WarnDays = 35,

        [Parameter()]
        [int]$AlertDays = 60,

        [Parameter()]
        [string]$Name = 'patch-status'
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $resolvedDir = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

    $okCount = @($Findings | Where-Object { $_.Estado -eq 'OK' }).Count
    $avisoCount = @($Findings | Where-Object { $_.Estado -eq 'Aviso' }).Count
    $altaCount = @($Findings | Where-Object { $_.Estado -eq 'Alta' }).Count

    $payload = [pscustomobject]@{
        Equipo     = $ComputerName
        Fecha      = $GeneratedAt.ToString('o')
        DiasAviso  = $WarnDays
        DiasAlerta = $AlertDays
        Resumen    = [pscustomobject]@{
            OK    = $okCount
            Aviso = $avisoCount
            Alta  = $altaCount
        }
        Hallazgos  = @($Findings)
        Historial  = @($History)
        Pendientes = @($Pending)
        Notas      = @($Notes)
    }

    $jsonPath = Join-Path -Path $resolvedDir -ChildPath "$Name.json"
    $htmlPath = Join-Path -Path $resolvedDir -ChildPath 'report.html'

    $json = $payload | ConvertTo-Json -Depth 8
    $html = New-PatchStatusHtml -Findings $Findings -History $History -Pending $Pending -Notes $Notes -ComputerName $ComputerName -GeneratedAt $GeneratedAt -WarnDays $WarnDays -AlertDays $AlertDays

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8NoBom)
    [System.IO.File]::WriteAllText($htmlPath, $html, $utf8NoBom)

    return [pscustomobject]@{
        Json = $jsonPath
        Html = $htmlPath
    }
}

Export-ModuleMember -Function Get-InstalledUpdateHistory, Test-LastPatch, Test-FailedUpdates, Get-PendingUpdates, Test-PendingUpdates, Test-PendingReboot, Test-UpdatePolicy, Test-UpdateService, Get-Uptime, New-PatchStatusHtml, Export-PatchStatusReport
