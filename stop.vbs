' Silent stopper: stops both services without showing any window.
' Result is written to logs\stop.log
Option Explicit
Dim sh, fso, root, logs, q, a, extra, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
If Right(root, 1) <> "\" Then root = root & "\"
logs = root & "logs\"
If Not fso.FolderExists(logs) Then fso.CreateFolder(logs)
q = Chr(34)
extra = ""
For Each a In WScript.Arguments
    extra = extra & " " & a
Next
cmd = "cmd /c " & q & q & root & "stop.bat" & q & extra & " /q >> " & q & logs & "stop.log" & q & " 2>&1" & q
sh.Run cmd, 0, True
