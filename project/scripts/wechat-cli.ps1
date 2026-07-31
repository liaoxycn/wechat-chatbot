[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('open', 'select', 'read', 'send')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Group,

    [Parameter(Position = 2)]
    [string]$Text,

    [int]$Limit = 20,
    [string]$Exe,
    [switch]$Exact,
    [switch]$Json,
    [switch]$Ocr,
    [switch]$Sender,
    [string]$SenderCache = '',
    [switch]$NoSenderCache,
    [string]$MediaDirectory = '',
    [string]$Python = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SenderCache)) {
    $SenderCache = Join-Path $PSScriptRoot '..\data\sender-cache.json'
}
if ([string]::IsNullOrWhiteSpace($MediaDirectory)) {
    $MediaDirectory = Join-Path $PSScriptRoot '..\data\media'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class NativeMouse {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;
}
'@

$script:Root = [System.Windows.Automation.AutomationElement]::RootElement
$script:ProcessName = 'Weixin'

function Get-OcrPython {
    param([string]$ConfiguredPython)

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPython)) {
        if (Test-Path -LiteralPath $ConfiguredPython -PathType Leaf) { return $ConfiguredPython }
        throw "指定的 Python 不存在：$ConfiguredPython"
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $venvPython -PathType Leaf) { return $venvPython }

    $homeDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $codexPython = Join-Path $homeDirectory '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path -LiteralPath $codexPython -PathType Leaf) { return $codexPython }

    throw '未找到 Codex Python。请运行 scripts\setup.ps1，或用 -Python 指定兼容解释器。'
}

function Get-WeChatWindow {
    param([int]$TimeoutSeconds = 10)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $processes = @(Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            if ($process.MainWindowHandle -ne 0) {
                $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
                if ($null -ne $window) { return $window }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw '未找到可操作的微信主窗口。请先登录微信。'
}

function Start-WeChat {
    $window = $null
    if (Get-Process -Name $script:ProcessName -ErrorAction SilentlyContinue) {
        $window = Get-WeChatWindow
    }
    elseif ($Exe) {
        if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
            throw "微信程序不存在：$Exe"
        }
        Start-Process -FilePath $Exe | Out-Null
        $window = Get-WeChatWindow -TimeoutSeconds 15
    }
    else {
        $apps = @(Get-StartApps | Where-Object { $_.Name -eq '微信' })
        if ($apps.Count -ne 1) {
            throw '无法唯一定位微信。请使用 -Exe 指定 Weixin.exe。'
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($apps[0].AppID)" | Out-Null
        $window = Get-WeChatWindow -TimeoutSeconds 15
    }

    $process = Get-Process -Id $window.Current.ProcessId
    if ($process.MainWindowHandle -eq 0) { throw '微信主窗口句柄无效。' }
    [NativeMouse]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        [NativeMouse]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 150
        if ([NativeMouse]::GetForegroundWindow() -eq $process.MainWindowHandle) { break }
    }
    return $window
}

function Find-ByAutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Parent,
        [string]$Id
    )
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $Id
    )
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Get-ListItems {
    param([System.Windows.Automation.AutomationElement]$Parent)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem
    )
    return @($Parent.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))
}

function Get-WeChatMessageType {
    param(
        [string]$Name,
        [string]$ClassName
    )

    if ($ClassName -eq 'mmui::ChatItemView' -and $Name -match '^\d{1,2}:\d{2}$|^星期|^昨天|^\d{1,2}月\d{1,2}日') { return 'time' }
    if ($Name -eq '图片' -or $ClassName -match 'Image|Picture') { return 'image' }
    if ($Name -match '^(动画表情|表情)$' -or $ClassName -match 'Emoji|Sticker') { return 'sticker' }
    if ($Name -match '^视频') { return 'video' }
    if ($Name -match '^文件') { return 'file' }
    if ($Name -match '撤回了一条消息|已解散该群聊|加入群聊|拍了拍|邀请.*加入') { return 'system' }
    return 'text'
}

function Get-SenderCache {
    $cache = @{ version = 1; senders = @{} }
    if (-not (Test-Path -LiteralPath $SenderCache -PathType Leaf)) { return $cache }
    try {
        $saved = Get-Content -Raw -LiteralPath $SenderCache -Encoding utf8 | ConvertFrom-Json
        if ($null -eq $saved.senders) { return $cache }
        foreach ($property in $saved.senders.PSObject.Properties) {
            $cache.senders[$property.Name] = @{
                name = [string]$property.Value.name
                confidence = [double]$property.Value.confidence
                updatedAt = [string]$property.Value.updatedAt
            }
        }
    }
    catch { Write-Verbose "发送者缓存无法读取，将重新建立：$($_.Exception.Message)" }
    return $cache
}

function Save-SenderCache {
    param([hashtable]$Cache)
    Write-Verbose "写入发送者缓存：$SenderCache"
    $directory = Split-Path -Parent $SenderCache
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $tempPath = "$SenderCache.tmp"
    $Cache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempPath -Encoding utf8
    Move-Item -LiteralPath $tempPath -Destination $SenderCache -Force
}

function Get-SenderCacheKey {
    param([string]$ChatName, [string]$SenderId)
    return "$ChatName|$SenderId"
}

function Find-ByName {
    param(
        [System.Windows.Automation.AutomationElement]$Parent,
        [string]$Name,
        [System.Windows.Automation.ControlType]$ControlType
    )
    $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name
    )
    $typeCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        $ControlType
    )
    $condition = New-Object System.Windows.Automation.AndCondition($nameCondition, $typeCondition)
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Invoke-Element {
    param([System.Windows.Automation.AutomationElement]$Element)

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return
    }
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        $pattern.Select()
        return
    }
    throw "控件不可调用：$($Element.Current.Name)"
}

function Click-Element {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [System.Windows.Automation.AutomationElement]$Element
    )

    $processId = $Window.Current.ProcessId
    $process = Get-Process -Id $processId
    if ($process.MainWindowHandle -eq 0) { throw '微信主窗口句柄无效。' }

    try {
        $point = $Element.GetClickablePoint()
    }
    catch {
        $bounds = $Element.Current.BoundingRectangle
        if ($bounds.Width -le 0 -or $bounds.Height -le 0) {
            throw "控件没有可点击区域：$($Element.Current.Name)"
        }
        $point = [System.Windows.Point]::new($bounds.X + $bounds.Width / 2, $bounds.Y + $bounds.Height / 2)
    }
    [NativeMouse]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 100
    [NativeMouse]::SetCursorPos([int]$point.X, [int]$point.Y) | Out-Null
    [NativeMouse]::mouse_event([NativeMouse]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    [NativeMouse]::mouse_event([NativeMouse]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

function Save-MediaCrop {
    param(
        [string]$SourcePath,
        [object]$Box,
        [string]$DestinationPath
    )

    $source = [System.Drawing.Bitmap]::new($SourcePath)
    try {
        $rectangle = [System.Drawing.Rectangle]::new(0, 0, $source.Width, $source.Height)
        if ($null -ne $Box) {
            $x = [Math]::Max(0, [int]$Box.x)
            $y = [Math]::Max(0, [int]$Box.y)
            $width = [Math]::Min($source.Width - $x, [int]$Box.width)
            $height = [Math]::Min($source.Height - $y, [int]$Box.height)
            if ($width -gt 0 -and $height -gt 0) {
                $rectangle = [System.Drawing.Rectangle]::new($x, $y, $width, $height)
            }
        }
        $crop = $source.Clone($rectangle, $source.PixelFormat)
        try { $crop.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png) }
        finally { $crop.Dispose() }
    }
    finally { $source.Dispose() }
}

function Select-WeChatGroup {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'select/send 需要提供群名。' }
    $titleId = 'content_view.top_content_view.title_h_view.left_v_view.left_content_v_view.left_ui_.big_title_line_h_view.current_chat_name_label'
    $currentTitle = Find-ByAutomationId -Parent $Window -Id $titleId
    if ($null -ne $currentTitle -and $currentTitle.Current.Name -like "$Name*") {
        return $currentTitle.Current.Name
    }

    $sessionList = Find-ByAutomationId -Parent $Window -Id 'session_list'
    if ($null -eq $sessionList) { throw '未找到微信会话列表。' }

    $matcher = {
        if ($Exact) { $_.Current.Name -eq $Name }
        else { $_.Current.Name -like "$Name*" }
    }
    $matches = @(Get-ListItems -Parent $sessionList | Where-Object $matcher)
    $searchPattern = $null

    if ($matches.Count -eq 0) {
        $search = Find-ByName -Parent $Window -Name '搜索' -ControlType ([System.Windows.Automation.ControlType]::Edit)
        if ($null -eq $search) { throw '未找到微信搜索框。' }
        if (-not $search.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$searchPattern)) {
            throw '微信搜索框不支持 ValuePattern。'
        }
        $searchPattern.SetValue($Name)
        Start-Sleep -Milliseconds 800
        $matches = @(Get-ListItems -Parent $Window | Where-Object $matcher)
    }
    if ($matches.Count -ne 1) {
        $names = ($matches | ForEach-Object { $_.Current.Name }) -join "`n"
        throw "群名匹配数量为 $($matches.Count)，需要唯一匹配。`n$names"
    }

    $selectedName = $matches[0].Current.Name
    Click-Element -Window $Window -Element $matches[0]
    Start-Sleep -Milliseconds 500
    if ($null -ne $searchPattern) {
        try { $searchPattern.SetValue('') } catch { }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $title = Find-ByAutomationId -Parent $Window -Id $titleId
        if ($null -ne $title -and $title.Current.Name -like "$Name*") {
            return $title.Current.Name
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "已点击会话项，但聊天窗口未切换到：$Name"
}

function Read-WeChatMessages {
    param([System.Windows.Automation.AutomationElement]$Window)

    $messageList = Find-ByAutomationId -Parent $Window -Id 'chat_message_list'
    if ($null -eq $messageList) { throw '未找到聊天消息列表。' }
    $titleId = 'content_view.top_content_view.title_h_view.left_v_view.left_content_v_view.left_ui_.big_title_line_h_view.current_chat_name_label'
    $chatTitle = Find-ByAutomationId -Parent $Window -Id $titleId
    $chatName = if ($null -ne $chatTitle) { $chatTitle.Current.Name } else { '' }
    $chatNameForOcr = ($chatName -replace '[^\p{L}\p{N}\s].*$', '').Trim()
    $items = @(Get-ListItems -Parent $messageList)
    if ($Limit -gt 0 -and $items.Count -gt $Limit) {
        $items = @($items | Select-Object -Last $Limit)
    }
    if ($items.Count -eq 0) { return @() }

    if (-not $Ocr -and $NoSenderCache -and -not $Sender) {
        $records = @($items | ForEach-Object {
            [pscustomobject]@{
                sender = $null
                senderConfidence = $null
                senderId = $null
                type = Get-WeChatMessageType -Name $_.Current.Name -ClassName $_.Current.ClassName
                content = $_.Current.Name
                mediaPath = $null
            }
        })
        if ($Json) { return ($records | ConvertTo-Json -Depth 4) }
        return $records
    }

    $ocrPython = Get-OcrPython -ConfiguredPython $Python
    $ocrHelper = Join-Path $PSScriptRoot 'wechat-ocr.py'
    if (-not (Test-Path -LiteralPath $ocrHelper -PathType Leaf)) {
        throw "未找到 OCR 辅助程序：$ocrHelper"
    }

    $process = Get-Process -Id $Window.Current.ProcessId
    [NativeMouse]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 250

    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("wechat-cli-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    $captures = @()
    try {
        for ($index = 0; $index -lt $items.Count; $index++) {
            $item = $items[$index]
            $rectangle = $item.Current.BoundingRectangle
            if ($rectangle.Width -le 0 -or $rectangle.Height -le 0) { continue }

            $path = Join-Path $tempDirectory ("message-{0:D3}.png" -f $index)
            $bitmap = New-Object System.Drawing.Bitmap([int]$rectangle.Width, [int]$rectangle.Height)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CopyFromScreen([int]$rectangle.X, [int]$rectangle.Y, 0, 0, $bitmap.Size)
                $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally {
                $graphics.Dispose()
                $bitmap.Dispose()
            }
            $captures += [pscustomobject]@{ Item = $item; Path = $path; Index = $index }
        }

        $senderMap = Get-SenderCache
        if (-not $Ocr) {
            $identityJsonPath = Join-Path $tempDirectory 'sender-identities.json'
            $identityLog = & $ocrPython $ocrHelper --identity --output $identityJsonPath @($captures.Path) 2>&1
            if ($LASTEXITCODE -ne 0) {
                $details = ($identityLog | Out-String).Trim()
                throw "发送者标识提取失败。$details"
            }
            if (-not (Test-Path -LiteralPath $identityJsonPath -PathType Leaf)) {
                throw '发送者标识提取未生成结果文件。'
            }
            $identities = @(Get-Content -Raw -LiteralPath $identityJsonPath -Encoding utf8 | ConvertFrom-Json)
            $records = @()
            $unknownSenders = @{}
            for ($index = 0; $index -lt $captures.Count; $index++) {
                $item = $captures[$index].Item
                $type = Get-WeChatMessageType -Name $item.Current.Name -ClassName $item.Current.ClassName
                $identity = $identities[$index]
                $senderId = if ($type -in @('time', 'system')) { $null } else { [string]$identity.senderId }
                $sender = $null
                $senderConfidence = $null
                if ($null -ne $senderId) {
                    if ($identity.side -eq 'right') {
                        $sender = '我'
                        $senderConfidence = 1.0
                    }
                    else {
                        $cacheKey = Get-SenderCacheKey -ChatName $chatName -SenderId $senderId
                        if ($senderMap.senders.ContainsKey($cacheKey)) {
                            $sender = $senderMap.senders[$cacheKey].name
                            $senderConfidence = $senderMap.senders[$cacheKey].confidence
                        }
                        else { $sender = '未知' }
                    }
                }
                $mediaPath = $null
                if ($type -in @('image', 'sticker')) {
                    New-Item -ItemType Directory -Force -Path $MediaDirectory | Out-Null
                    $mediaName = "{0:yyyyMMdd-HHmmss}-{1:D3}-{2}.png" -f (Get-Date), $captures[$index].Index, $type
                    $mediaPath = Join-Path (Resolve-Path $MediaDirectory) $mediaName
                    Save-MediaCrop -SourcePath $captures[$index].Path -Box $identity.mediaBox -DestinationPath $mediaPath
                }
                $record = [pscustomobject]@{
                    sender = $sender
                    senderConfidence = $senderConfidence
                    senderId = $senderId
                    type = $type
                    content = $item.Current.Name
                    mediaPath = $mediaPath
                }
                $records += $record
                if ($Sender -and $sender -eq '未知') {
                    $priority = if ($type -eq 'text') { 2 } else { 1 }
                    if (-not $unknownSenders.ContainsKey($senderId) -or $priority -gt $unknownSenders[$senderId].Priority) {
                        $unknownSenders[$senderId] = [pscustomobject]@{ Capture = $captures[$index]; Record = $record; Priority = $priority }
                    }
                }
            }

            if ($Sender -and $unknownSenders.Count -gt 0) {
                $unknownSenderEntries = @($unknownSenders.Values)
                $senderOcrJsonPath = Join-Path $tempDirectory 'unknown-senders-ocr.json'
                $previousPythonEncoding = $env:PYTHONIOENCODING
                $env:PYTHONIOENCODING = 'utf-8'
                try { $senderOcrLog = & $ocrPython $ocrHelper --output $senderOcrJsonPath @($unknownSenderEntries.Capture.Path) 2>&1 }
                finally { $env:PYTHONIOENCODING = $previousPythonEncoding }
                if ($LASTEXITCODE -ne 0) {
                    $details = ($senderOcrLog | Out-String).Trim()
                    throw "发送者 OCR 执行失败。$details"
                }
                if (-not (Test-Path -LiteralPath $senderOcrJsonPath -PathType Leaf)) {
                    throw '发送者 OCR 未生成结果文件。'
                }
                $senderOcrResults = @(Get-Content -Raw -LiteralPath $senderOcrJsonPath -Encoding utf8 | ConvertFrom-Json)
                $cacheDirty = $false
                for ($ocrIndex = 0; $ocrIndex -lt $unknownSenderEntries.Count; $ocrIndex++) {
                    $pending = $unknownSenderEntries[$ocrIndex]
                    $ocr = $senderOcrResults[$ocrIndex]
                    $candidate = @($ocr.lines | Where-Object {
                        [double]$_.y -lt [Math]::Min(30, [double]$ocr.height * 0.4) -and
                        [double]$_.x -lt [double]$ocr.width * 0.55 -and
                        $_.text -ne $pending.Record.content -and
                        ($chatNameForOcr.Length -eq 0 -or $_.text -notlike "$chatNameForOcr*")
                    } | Sort-Object y, x | Select-Object -First 1)
                    if ($candidate.Count -eq 0) { continue }

                    $resolvedSender = $candidate[0].text
                    $resolvedConfidence = [double]$candidate[0].confidence
                    foreach ($record in @($records | Where-Object { $_.senderId -eq $pending.Record.senderId })) {
                        $record.sender = $resolvedSender
                        $record.senderConfidence = $resolvedConfidence
                    }
                    $cacheKey = Get-SenderCacheKey -ChatName $chatName -SenderId $pending.Record.senderId
                    $senderMap.senders[$cacheKey] = @{
                        name = $resolvedSender
                        confidence = $resolvedConfidence
                        updatedAt = (Get-Date).ToString('o')
                    }
                    $cacheDirty = $true
                }
                if ($cacheDirty) { Save-SenderCache -Cache $senderMap }
            }
            if ($Json) { return ($records | ConvertTo-Json -Depth 4) }
            return $records
        }

        $ocrJsonPath = Join-Path $tempDirectory 'ocr-results.json'
        $previousPythonEncoding = $env:PYTHONIOENCODING
        $env:PYTHONIOENCODING = 'utf-8'
        try { $ocrLog = & $ocrPython $ocrHelper --output $ocrJsonPath @($captures.Path) 2>&1 }
        finally { $env:PYTHONIOENCODING = $previousPythonEncoding }
        if ($LASTEXITCODE -ne 0) {
            $details = ($ocrLog | Out-String).Trim()
            throw "OCR 辅助程序执行失败。$details"
        }
        if (-not (Test-Path -LiteralPath $ocrJsonPath -PathType Leaf)) {
            throw 'OCR 辅助程序未生成结果文件。'
        }
        $ocrResults = @(Get-Content -Raw -LiteralPath $ocrJsonPath -Encoding utf8 | ConvertFrom-Json)
        $records = @()
        $cacheDirty = $false
        for ($index = 0; $index -lt $captures.Count; $index++) {
            $capture = $captures[$index]
            $item = $capture.Item
            $name = $item.Current.Name
            $className = $item.Current.ClassName
            $ocr = $ocrResults[$index]

            $type = Get-WeChatMessageType -Name $name -ClassName $className

            $sender = $null
            $senderConfidence = $null
            $senderId = if ($type -in @('time', 'system')) { $null } else { [string]$ocr.senderId }
            if ($type -notin @('time', 'system')) {
                $outgoing = $ocr.side -eq 'right'
                if ($outgoing) {
                    $sender = '我'
                    $senderConfidence = 1.0
                }
                else {
                    $candidate = @($ocr.lines | Where-Object {
                        [double]$_.y -lt [Math]::Min(30, [double]$ocr.height * 0.4) -and
                        [double]$_.x -lt [double]$ocr.width * 0.55 -and
                        $_.text -ne $name -and
                        ($chatNameForOcr.Length -eq 0 -or $_.text -notlike "$chatNameForOcr*")
                    } | Sort-Object y, x | Select-Object -First 1)
                    if ($candidate.Count -gt 0) {
                        $sender = $candidate[0].text
                        $senderConfidence = [double]$candidate[0].confidence
                    }
                    else {
                        $sender = '未知'
                    }
                }
            }

            if ($sender -notin @($null, '未知', '我') -and $null -ne $senderId) {
                $cacheKey = Get-SenderCacheKey -ChatName $chatName -SenderId $senderId
                $senderMap.senders[$cacheKey] = @{
                    name = $sender
                    confidence = $senderConfidence
                    updatedAt = (Get-Date).ToString('o')
                }
                $cacheDirty = $true
            }

            $mediaPath = $null
            if ($type -in @('image', 'sticker')) {
                New-Item -ItemType Directory -Force -Path $MediaDirectory | Out-Null
                $mediaName = "{0:yyyyMMdd-HHmmss}-{1:D3}-{2}.png" -f (Get-Date), $capture.Index, $type
                $mediaPath = Join-Path (Resolve-Path $MediaDirectory) $mediaName
                Save-MediaCrop -SourcePath $capture.Path -Box $ocr.mediaBox -DestinationPath $mediaPath
            }

            $records += [pscustomobject]@{
                sender = $sender
                senderConfidence = $senderConfidence
                senderId = $senderId
                type = $type
                content = $name
                mediaPath = $mediaPath
            }
        }

        if ($cacheDirty) { Save-SenderCache -Cache $senderMap }
        else { Write-Verbose '本次 OCR 未产生可缓存的发送者昵称。' }

        if ($Json) { return ($records | ConvertTo-Json -Depth 4) }
        return $records
    }
    finally {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Send-WeChatMessage {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { throw 'send 需要提供非空消息。' }
    $input = Find-ByAutomationId -Parent $Window -Id 'chat_input_field'
    if ($null -eq $input) { throw '未找到聊天输入框。' }

    $valuePattern = $null
    if (-not $input.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
        throw '聊天输入框不支持 ValuePattern，无法可靠输入。'
    }
    $valuePattern.SetValue($Message)

    $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        '发送'
    )
    $buttons = @($Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $nameCondition) |
        Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button })
    $sendButton = @($buttons | Where-Object { $_.Current.IsEnabled }) | Select-Object -First 1
    if ($null -eq $sendButton) { throw '未找到可用的发送按钮。' }
    Click-Element -Window $Window -Element $sendButton

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 150
        $currentInput = Find-ByAutomationId -Parent $Window -Id 'chat_input_field'
        $currentValue = $null
        $currentValuePattern = $null
        if ($null -ne $currentInput -and $currentInput.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$currentValuePattern)) {
            $currentValue = $currentValuePattern.Current.Value
        }
        $messageList = Find-ByAutomationId -Parent $Window -Id 'chat_message_list'
        $messageFound = $null -ne $messageList -and @(Get-ListItems -Parent $messageList | Where-Object { $_.Current.Name -eq $Message }).Count -gt 0
        if ([string]::IsNullOrEmpty($currentValue) -and $messageFound) { return }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw '点击发送后未能在消息列表中确认该消息。'
}

switch ($Command) {
    'open' {
        $window = Start-WeChat
        "已打开微信：$($window.Current.Name)"
    }
    'select' {
        $window = Start-WeChat
        $selected = Select-WeChatGroup -Window $window -Name $Group
        "已选中：$selected"
    }
    'read' {
        $window = Start-WeChat
        if (-not [string]::IsNullOrWhiteSpace($Group)) {
            $null = Select-WeChatGroup -Window $window -Name $Group
        }
        Read-WeChatMessages -Window $window
    }
    'send' {
        $window = Start-WeChat
        $null = Select-WeChatGroup -Window $window -Name $Group
        Send-WeChatMessage -Window $window -Message $Text
        '发送完成'
    }
}
