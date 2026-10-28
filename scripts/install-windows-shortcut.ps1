$ErrorActionPreference = 'Stop'
$executable = Join-Path $PSScriptRoot 'xiaomi_lightbar_desktop.exe'
if (-not (Test-Path $executable)) { throw 'The application executable was not found.' }
$programs = [Environment]::GetFolderPath('Programs')
$shortcutPath = Join-Path $programs 'Xiaomi Lightbar.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $executable
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Xiaomi Lightbar Controller'
$shortcut.Save()
Write-Host "Created Start menu shortcut: $shortcutPath"
