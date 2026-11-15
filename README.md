# patch-status-report

[![CI](https://github.com/samuelmartindelgado/patch-status-report/actions/workflows/ci.yml/badge.svg)](https://github.com/samuelmartindelgado/patch-status-report/actions/workflows/ci.yml)

Informe del estado de parches de Windows en un solo comando. Responde a las tres
preguntas que siempre aparecen en una auditoría: **cuándo se parcheó el equipo por
última vez**, **qué actualizaciones están pendientes** y **si hay un reinicio
pendiente**. Es una herramienta de **solo lectura**: nunca instala, descarga ni
reinicia nada.

## Por qué importa

Un equipo sin parchear es la vía de entrada más habitual en un incidente. Los
técnicos de sistemas necesitan una foto rápida y fiable antes de una auditoría,
un alta de equipo o una revisión de cumplimiento: no basta con decir "Windows
Update está activado", hay que demostrar cuándo se aplicó el último parche y si
quedó alguno a medias. Este script recoge esa información sin tocar el equipo, la
resume por estados y deja un informe HTML que se puede adjuntar a un ticket.

## Qué revisa

| Comprobación | Qué hace | Estados |
| --- | --- | --- |
| Último parche | Busca la última actualización acumulativa o de seguridad instalada correctamente | OK / Aviso (>35 días) / Alta (>60 días o ninguna) |
| Actualizaciones fallidas | Detecta fallos o errores de los últimos 30 días que no se reinstalaron después | OK / Aviso |
| Actualizaciones pendientes | Consulta Windows Update (`IsInstalled=0 and IsHidden=0 and Type='Software'`) | OK / Aviso / Alta (críticas) |
| Reinicio pendiente | Lee CBS `RebootPending`, WU `RebootRequired` y `PendingFileRenameOperations` | OK / Aviso |
| Directiva de actualizaciones | Revisa `NoAutoUpdate`, `AUOptions` y `WUServer` (WSUS) | OK / Alta |
| Servicio Windows Update | Comprueba que `wuauserv` no esté deshabilitado | OK / Alta |
| Tiempo encendido | Días desde el último arranque (`LastBootUpTime`) | OK / Aviso (>30 días) |

Además, el informe HTML incluye las **últimas 15 actualizaciones instaladas** y
la tabla de **actualizaciones pendientes**.

## Uso

```powershell
# Informe por consola
./Get-PatchStatus.ps1

# Sin consultar Windows Update en línea (solo datos locales, más rápido)
./Get-PatchStatus.ps1 -SkipOnlineSearch

# Generar JSON y HTML
./Get-PatchStatus.ps1 -OutputPath ./salida

# Cambiar los umbrales de aviso y alerta
./Get-PatchStatus.ps1 -WarnDays 30 -AlertDays 45
```

Parámetros:

| Parámetro | Por defecto | Descripción |
| --- | --- | --- |
| `-WarnDays` | `35` | Días sin parchear a partir de los cuales se muestra un aviso |
| `-AlertDays` | `60` | Días sin parchear a partir de los cuales se muestra una alerta |
| `-SkipOnlineSearch` | desactivado | No consulta Windows Update; revisa solo lo local |
| `-OutputPath` | vacío | Carpeta donde se escriben `patch-status.json` y `report.html` |

Códigos de salida: `0` todo OK, `1` algún aviso, `2` alguna alerta.

Requisitos: Windows PowerShell 5.1 o PowerShell 7. No usa módulos externos. No
necesita administrador: lo que no pueda leer se omite con una nota.

## Ejemplo de salida

Datos **ficticios** del equipo `PC-DEMO`:

```text
Estado de parches - PC-DEMO - 2026-05-12 09:30
Umbrales: aviso a los 35 días, alerta a los 60 días

[OK] Último parche
       La última actualización acumulativa o de seguridad se instaló hace 12 días.
       Valor: 2026-04-30 (KB5000001) - hace 12 días
[OK] Actualizaciones fallidas
       No hay actualizaciones fallidas sin resolver en los últimos 30 días.
[Alta] Actualizaciones pendientes
       Hay 1 actualización(es) pendiente(s) marcadas como críticas por Microsoft.
       Valor: Críticas: KB5000002
       Recomendado: Instalar las actualizaciones críticas cuanto antes
[Aviso] Reinicio pendiente
       El equipo tiene un reinicio pendiente para terminar de aplicar cambios.
       Valor: CBS RebootPending
       Recomendado: Reiniciar el equipo fuera del horario de trabajo
[OK] Directiva de actualizaciones
       No hay directiva que desactive las actualizaciones automáticas.
[OK] Servicio Windows Update
       El servicio Windows Update no está deshabilitado.
       Valor: wuauserv: Manual
[Aviso] Tiempo encendido
       El equipo lleva 41 días sin reiniciar; los parches del kernel no se aplican hasta reiniciar.

Resumen: 4 OK, 2 avisos, 1 alta
Informe JSON: C:\salida\patch-status.json
Informe HTML: C:\salida\report.html
Solo lectura: no se ha instalado, descargado ni reiniciado nada.
```

## Cómo corregir cada hallazgo

- **Último parche (Aviso/Alta)**: abrir Configuración > Windows Update y aplicar
  la última actualización acumulativa; en entornos gestionados, forzar la
  sincronización con WSUS.
- **Actualizaciones fallidas (Aviso)**: revisar el código de error en el historial
  de Windows Update y reinstalar las KB indicadas. Si el error se repite,
  comprobar espacio en disco y el estado de `C:\Windows\SoftwareDistribution`.
- **Actualizaciones pendientes (Aviso/Alta)**: instalar las actualizaciones desde
  Windows Update o aprobarlas en WSUS. Las marcadas como críticas deben aplicarse
  cuanto antes.
- **Reinicio pendiente (Aviso)**: programar un reinicio controlado fuera del
  horario de trabajo para completar la instalación.
- **Directiva de actualizaciones (Alta)**: revisar la GPO que pone
  `NoAutoUpdate = 1` y permitir las actualizaciones automáticas o gestionarlas
  por WSUS.
- **Servicio Windows Update (Alta)**: volver a poner `wuauserv` en inicio manual
  o automático (`Set-Service -Name wuauserv -StartupType Manual`).
- **Tiempo encendido (Aviso)**: reiniciar el equipo; los parches del kernel no se
  aplican hasta el siguiente arranque.

## Solo lectura

El script únicamente lee el historial de Windows Update, las claves del registro
indicadas y el estado del servicio. No ejecuta `wuauclt`, no descarga nada, no
instala parches y no reinicia el equipo. La columna "Solución" del informe son
ejemplos para el técnico y no se ejecutan.

## Licencia

MIT. Consulta el archivo [LICENSE](LICENSE).

---

## English summary

Read-only Windows patch status report. It shows when the machine was last patched,
which updates are pending, whether a reboot is required, the Windows Update policy
(`NoAutoUpdate`, `AUOptions`, WSUS) and `wuauserv` status, plus uptime in days. It
never installs, downloads or reboots anything. Works on Windows PowerShell 5.1 and
PowerShell 7 without external modules. Use `-OutputPath` to get a standalone HTML
report (inline CSS, dark mode, escaped text) and a JSON file. Exit codes: `0` all
OK, `1` warning, `2` alert.
