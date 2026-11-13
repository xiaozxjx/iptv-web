' Silent launcher for IPTV web player + local ysp-live source.
' Double-click this file for a completely windowless start (no console flash).
' Logs: logs\node.log, logs\start-status.txt (local source output is discarded)
' Runtimes: runtime\node\node.exe + runtime\python\python.exe are bundled - nothing to install.
' If a runtime is missing, logs\node.log prints the official download links.
' Local source auto-restarts every 3h via its own supervisor (logs\restart.log).
Option Explicit

Dim sh, fso, env, root, logs, nodeExe, pyExe, webPort, srcPort
Dim noLocal, checkOnly, a, ts, status, startedWeb, startedSrc, fatal
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set env = sh.Environment("PROCESS")

root = fso.GetParentFolderName(WScript.ScriptFullName)
If Right(root, 1) <> "\" Then root = root & "\"
logs = root & "logs\"
If Not fso.FolderExists(logs) Then fso.CreateFolder(logs)

noLocal = (LCase(env("IPTV_NOLOCAL")) = "1")
checkOnly = False
For Each a In WScript.Arguments
    If LCase(a) = "/check" Then checkOnly = True
    If LCase(a) = "/nolocal" Then noLocal = True
Next

webPort = env("PORT")
If webPort = "" Then webPort = "8088"
srcPort = env("YSP_PORT")
If srcPort = "" Then srcPort = "20345"

nodeExe = FindNode()
pyExe = FindPython()

If checkOnly Then
    If IsCscript() Then
        WScript.Echo "IPTV web player : http://127.0.0.1:" & webPort
        WScript.Echo "Default source  : http://127.0.0.1:" & srcPort & "/all.m3u"
        If nodeExe = "" Then
            WScript.Echo "Node            : NOT FOUND - install Node.js LTS from https://nodejs.org/zh-cn/download"
        Else
            WScript.Echo "Node            : " & nodeExe
        End If
        If pyExe = "" Then
            WScript.Echo "Python          : NOT FOUND - install Python 3 from https://www.python.org/downloads/windows/"
        Else
            WScript.Echo "Python          : " & pyExe
        End If
        WScript.Echo "Hidden windows  : yes"
        WScript.Echo "Logs            : " & logs
    End If
    WScript.Quit 0
End If

status = ""
startedWeb = False
startedSrc = False
fatal = False
AddLine "===== start ====="

If ServiceUp(webPort, "/health") Then
    AddLine "web server already running on " & webPort
ElseIf nodeExe = "" Then
    ReportNodeMissing
    AddLine "web server NOT started - Node.js missing"
    AddLine "  install: https://nodejs.org/zh-cn/download (see logs\node.log)"
    fatal = True
Else
    LaunchHidden nodeExe, Q(root & "server.js"), "node.log"
    startedWeb = True
    AddLine "web server started (hidden) on " & webPort
End If

If Not noLocal Then
    If ServiceUp(srcPort, "/health") Then
        AddLine "local source already running on " & srcPort
    ElseIf pyExe = "" Then
        ReportPythonMissing
        AddLine "local source NOT started - Python 3 missing"
        AddLine "  install: https://www.python.org/downloads/windows/ (see logs\node.log)"
    Else
        ' No --_worker here: ysp-live.py runs its own supervisor, which restarts
        ' the local source every 3 hours (YSP_RESTART_HOURS to change, 0 disables).
        ' Optional extra daily restart: YSP_RESTART_AT=02:00 (earliest deadline wins).
        ' Restart events are recorded in logs\restart.log.
        LaunchHidden pyExe, Q(root & "ysp-live.py") & " " & srcPort & " --no-4k", ""
        startedSrc = True
        AddLine "local source started (hidden, auto-restart every 3h) on " & srcPort
    End If
Else
    AddLine "local source skipped (/nolocal)"
End If

WScript.Sleep 1800
If startedWeb Then
    If ServiceUp(webPort, "/health") Then
        AddLine "web server check: OK"
    Else
        AddLine "web server check: FAILED - see logs\node.log"
    End If
End If
If startedSrc Then
    If ServiceUp(srcPort, "/health") Then
        AddLine "local source check: OK"
    Else
        AddLine "local source check: FAILED - local source output is discarded"
    End If
End If

Set ts = fso.OpenTextFile(logs & "start-status.txt", 8, True)
ts.Write status
ts.Close

If IsCscript() Then WScript.Echo Replace(status, vbCr, "")
If fatal Then WScript.Quit 2
WScript.Quit 0

' ---------------- helpers ----------------
Function Stamp()
    Dim d
    d = Now
    Stamp = "[" & Year(d) & "-" & Right("0" & Month(d), 2) & "-" & Right("0" & Day(d), 2) & " " & Right("0" & Hour(d), 2) & ":" & Right("0" & Minute(d), 2) & ":" & Right("0" & Second(d), 2) & "]"
End Function

Sub AddLine(s)
    status = status & Stamp() & " " & s & vbCrLf
End Sub

Sub AppendLog(fileName, s)
    Dim t
    Set t = fso.OpenTextFile(logs & fileName, 8, True)
    t.WriteLine Stamp() & " " & s
    t.Close
End Sub

Function Q(s)
    Q = Chr(34) & s & Chr(34)
End Function

Function FileOK(p)
    FileOK = False
    If p = "" Then Exit Function
    If fso.FileExists(p) Then FileOK = True
End Function

Function InVersions(base, exeName)
    Dim f, p
    InVersions = ""
    If Not fso.FolderExists(base) Then Exit Function
    For Each f In fso.GetFolder(base).SubFolders
        p = f.Path & "\" & exeName
        If fso.FileExists(p) Then
            InVersions = p
            Exit Function
        End If
    Next
End Function

Function FindNode()
    Dim p
    If FileOK(env("NODE_EXE")) Then FindNode = env("NODE_EXE") : Exit Function
    If FileOK(env("IPTV_NODE")) Then FindNode = env("IPTV_NODE") : Exit Function
    If FileOK(root & "runtime\node\node.exe") Then FindNode = root & "runtime\node\node.exe" : Exit Function
    If FileOK(root & "node.exe") Then FindNode = root & "node.exe" : Exit Function
    p = sh.ExpandEnvironmentStrings("%ProgramFiles%\nodejs\node.exe")
    If FileOK(p) Then FindNode = p : Exit Function
    p = sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%\nodejs\node.exe")
    If FileOK(p) Then FindNode = p : Exit Function
    p = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\nodejs\node.exe")
    If FileOK(p) Then FindNode = p : Exit Function
    p = InVersions(sh.ExpandEnvironmentStrings("%USERPROFILE%\.workbuddy\binaries\node\versions"), "node.exe")
    If p <> "" Then FindNode = p : Exit Function
    p = FindOnPath("node.exe")
    If p <> "" Then FindNode = p : Exit Function
    FindNode = ""
End Function

Function FindPython()
    Dim p
    If FileOK(env("PY_EXE")) Then FindPython = env("PY_EXE") : Exit Function
    If FileOK(env("IPTV_PY")) Then FindPython = env("IPTV_PY") : Exit Function
    If FileOK(root & "runtime\python\python.exe") Then FindPython = root & "runtime\python\python.exe" : Exit Function
    If FileOK(root & "python.exe") Then FindPython = root & "python.exe" : Exit Function
    p = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python313\python.exe")
    If FileOK(p) Then FindPython = p : Exit Function
    p = InVersions(sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python"), "python.exe")
    If p <> "" Then FindPython = p : Exit Function
    p = InVersions(sh.ExpandEnvironmentStrings("%USERPROFILE%\.workbuddy\binaries\python\versions"), "python.exe")
    If p <> "" Then FindPython = p : Exit Function
    p = FindOnPath("python.exe")
    If p <> "" Then FindPython = p : Exit Function
    p = FindOnPath("py.exe")
    If p <> "" Then FindPython = p : Exit Function
    FindPython = ""
End Function

' Look for an executable in every directory of this process's PATH (no window, no shell).
Function FindOnPath(exeName)
    Dim dirs, i, p
    FindOnPath = ""
    dirs = Split(env("PATH"), ";")
    For i = 0 To UBound(dirs)
        p = Trim(dirs(i))
        If p <> "" Then
            If Right(p, 1) <> "\" Then p = p & "\"
            If FileOK(p & exeName) Then
                FindOnPath = p & exeName
                Exit Function
            End If
        End If
    Next
End Function

' Everything a user needs to fix a machine without Node.js goes into the log itself.
' Keep these lines pure ASCII: a .vbs is read in the system ANSI codepage.
Sub ReportNodeMissing()
    AppendLog "node.log", "===== node.log started ====="
    AppendLog "node.log", "[ERROR] Node.js NOT found on this PC - web server was NOT started."
    AppendLog "node.log", "  Download Node.js (LTS, Windows Installer .msi): https://nodejs.org/zh-cn/download"
    AppendLog "node.log", "  Direct link, LTS v26.13.0 Windows x64 .msi: https://nodejs.org/dist/v26.13.0/node-v26.13.0-x64.msi"
    AppendLog "node.log", "  Portable .zip (no install needed): https://nodejs.org/dist/v26.13.0/node-v26.13.0-win-x64.zip"
    AppendLog "node.log", "  No install needed: unzip that .zip into runtime\node\ (node.exe at runtime\node\node.exe),"
    AppendLog "node.log", "  or put node.exe in this folder, or set NODE_EXE to its full path."
    AppendLog "node.log", "  After installing, run start.vbs again (verify with: node -v)."
End Sub

Sub ReportPythonMissing()
    AppendLog "node.log", "[WARN] Python 3 NOT found on this PC - local source (ysp-live.py) was NOT started."
    AppendLog "node.log", "  Download Python 3 (Windows installer): https://www.python.org/downloads/windows/"
    AppendLog "node.log", "  Portable embeddable zip (64-bit, no install, stdlib only): https://www.python.org/ftp/python/3.15.2/python-3.15.2-embed-amd64.zip"
    AppendLog "node.log", "  Unzip it into runtime\python\ (python.exe at runtime\python\python.exe) - no pip needed."
    AppendLog "node.log", "  During a normal install check 'Add python.exe to PATH'; or set PY_EXE to its full path."
    AppendLog "node.log", "  Or run start.bat /nolocal and pick a remote source in the page."
End Sub

Function IsCscript()
    IsCscript = (InStr(1, LCase(WScript.FullName), "cscript.exe") > 0)
End Function

Function ServiceUp(port, path)
    Dim x
    ServiceUp = False
    On Error Resume Next
    Set x = CreateObject("MSXML2.ServerXMLHTTP")
    x.setTimeouts 400, 400, 900, 900
    x.open "GET", "http://127.0.0.1:" & port & path, False
    x.send
    If Err.Number = 0 Then ServiceUp = True
    Set x = Nothing
    On Error GoTo 0
End Function

Sub LaunchHidden(exe, args, logFile)
    Dim cmdLine, target
    If logFile = "" Then
        target = "nul"
    Else
        AppendLog logFile, "===== " & logFile & " started ====="
        target = Q(logs & logFile)
    End If
    cmdLine = "cmd /c " & Q(Q(exe) & " " & args & " >> " & target & " 2>&1")
    sh.Run cmdLine, 0, False
End Sub
