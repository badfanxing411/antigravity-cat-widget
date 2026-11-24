Option Explicit
Dim supervisorShell, supervisorFiles, supervisorRoot, winDir, supervisorCommand, supervisorExit
Set supervisorShell = CreateObject("WScript.Shell")
Set supervisorFiles = CreateObject("Scripting.FileSystemObject")
supervisorRoot = supervisorFiles.GetParentFolderName(WScript.ScriptFullName)
winDir = supervisorShell.ExpandEnvironmentStrings("%WINDIR%")
supervisorCommand = """" & winDir & "\System32\conhost.exe"" --headless """ & winDir & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & supervisorRoot & "\runtime\supervisor.ps1"""
supervisorExit = supervisorShell.Run(supervisorCommand, 0, True)
WScript.Quit supervisorExit
