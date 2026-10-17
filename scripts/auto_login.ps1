#requires -Version 5.1
<#
.SYNOPSIS
    河南师范大学校园网（HTU_Student）自动认证脚本
.DESCRIPTION
    检测外网连通性，不通时自动捕获 Portal 跳转并提交 quickauth.do 完成认证。
    设计为被 Windows 任务计划周期性调用，无需用户登录。
.NOTES
    凭据只从本地 config.ini 读取，不上传任何外部服务。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

# ---------- 全局：关闭系统代理，确保内网请求直连 ----------
[System.Net.WebRequest]::DefaultWebProxy = $null
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'config.ini'
}

# 日志路径先给默认值：保证任何早期错误（配置缺失、解析失败等）都能落盘。
# 读到 config.ini 后由 Initialize-Log 覆盖为配置值。
$script:LogFile = Join-Path (Split-Path -Parent $scriptDir) 'logs\auto_login.log'
$script:MaxLogBytes = 5MB

# ---------- 常量（用函数而非脚本变量：tests 通过 AST 只提取函数定义，变量取不到） ----------
function Get-BrowserUserAgent {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
}

function Get-PortalMark {
    # 认证页特征：命中任一即视为 HTTP 被 BRAS 劫持
    return 'portal\.do|quickauth|wlanuserip|10\.101\.2\.194|srun_portal|login\.do|userid'
}

# ---------- 日志 ----------
function Initialize-Log {
    <#
        设置日志文件路径、创建目录，并在超过阈值时归档（只保留一份历史）。
        日志按分钟增长，不轮转的话 -Wait 追踪会越来越慢。
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $script:LogFile = $Path
    $dir = Split-Path -Parent $Path
    try {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        if (Test-Path -LiteralPath $Path) {
            if ((Get-Item -LiteralPath $Path).Length -gt $script:MaxLogBytes) {
                $bak = "$Path.1"
                Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $Path -Destination $bak -Force
            }
        }
    } catch {
        # 轮转失败不影响写日志
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not $script:LogFile) { return }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 日志写不进去也不能影响主流程
    }
}

# ---------- 配置 ----------
function Read-Ini {
    param([string]$Path)
    $ini = [ordered]@{}
    $section = 'Default'
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
            continue
        }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
        $ini[$section][$key] = $val
    }
    return $ini
}

function Get-ConfigInt {
    <#
        读取整数配置项，键缺失或值非法时返回默认值。
        （直接 [int]$cfg[...] 会把缺失项静默变成 0，导致重试循环一次都不执行）
    #>
    param($Ini, [string]$Section, [string]$Key, [int]$Default)
    $raw = $null
    try {
        if ($Ini.Contains($Section) -and $Ini[$Section].Contains($Key)) {
            $raw = $Ini[$Section][$Key]
        }
    } catch {
        return $Default
    }
    $v = 0
    if ([int]::TryParse([string]$raw, [ref]$v) -and $v -ge 0) { return $v }
    return $Default
}

# ---------- 时间戳（探测节流 / 心跳） ----------
function Read-TimestampFile {
    <#
        读取 ISO-8601 时间戳文件。文件不存在返回 $null；
        内容为空或损坏时删除该文件并返回 $null——否则一次写坏会让脚本永久失败。
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty' }
        return [DateTime]::Parse($raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Write-Log "时间戳文件内容异常，已删除并视为从未执行: $Path" 'WARN'
        return $null
    }
}

function Write-TimestampFile {
    param([string]$Path)
    try {
        (Get-Date).ToString('o') | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "写时间戳文件失败（不影响认证）: $Path" 'WARN'
    }
}

# ---------- HTTP 探测 ----------
function Extract-PortalUrl {
    <#
        从被劫持的页面 HTML 里提取完整 portal.do URL（深澜页面通常有
        location.href="http://10.101.2.194:6060/portal.do?..." 或 meta refresh）。
        提取不到则返回空。
    #>
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    if ($Body -match 'https?://[^"''<>\s]*portal\.do[^"''<>\s]*') {
        return $Matches[0]
    }
    if ($Body -match '(?:meta[^>]*refresh[^>]*content="[^"]*url\s*=\s*)?([^"''<>\s]*portal\.do[^"''<>\s]*)') {
        $u = $Matches[1]
        if ($u -match '^https?://') { return $u }
    }
    return ''
}

function Read-ResponseBody {
    <#
        读取响应体（最多 MaxChars 个字符），失败返回空字符串。
        不负责关闭响应流，由调用方统一 Close。
    #>
    param($Response, [int]$MaxChars = 8192)
    try {
        $sr = New-Object System.IO.StreamReader($Response.GetResponseStream())
        try {
            $buf = New-Object char[] $MaxChars
            $read = $sr.Read($buf, 0, $MaxChars)
            if ($read -le 0) { return '' }
            return (-join $buf[0..($read - 1)])
        } finally {
            $sr.Close()
        }
    } catch {
        return ''
    }
}

function Resolve-ProbeResponse {
    <#
        把一次 HTTP 响应归类为 ok / captive / fail。
        3xx 看 Location；2xx 与 4xx/5xx 一律读响应体看是否被注入了认证页
        （深澜透明劫持会返回 200，部分 BRAS 会用 403 承载劫持页）。
    #>
    param($Response, [string]$Url)
    $mark = Get-PortalMark
    $code = 0
    try { $code = [int]$Response.StatusCode } catch { $code = 0 }

    if ($code -ge 300 -and $code -lt 400) {
        $loc = $null
        try { $loc = $Response.Headers['Location'] } catch { $loc = $null }
        if ($loc -and $loc -match $mark) {
            return @{ Status = 'captive'; Location = $loc }
        }
        # 跳转但非认证页（如 http→https 正常跳转），说明能上网
        return @{ Status = 'ok'; Location = '' }
    }

    $body = Read-ResponseBody -Response $Response
    if ($body -and $body -match $mark) {
        $p = Extract-PortalUrl -Body $body
        if ($p) {
            return @{ Status = 'captive'; Location = $p }
        }
        # 确认被劫持但提不出入口 URL：Location 留空，交由主流程兜底拉取 portal.do，
        # 不能拿探测地址顶替（那样会得到空参数且认证必然失败）
        return @{ Status = 'captive'; Location = '' }
    }

    if ($code -ge 200 -and $code -lt 300) {
        return @{ Status = 'ok'; Location = '' }
    }
    return @{ Status = 'fail'; Location = '' }
}

function Http-Probe {
    <#
        对单个 URL 做 HTTP 探测（不跟随重定向），并检查响应是否被 BRAS 劫持成认证页。
        返回 @{Status='ok'|'captive'|'fail'; Location='portal地址'}
        - ok: 正常访问（2xx 且页面无 portal 特征；或 3xx 但跳转目标不是认证页）
        - captive: 被劫持到认证页（深澜两种劫持方式都会命中：
            a) 3xx + Location 指向 portal；b) 200/403 + 页面 HTML 含 portal.do 特征）
        - fail: 连接失败（无网络 / 目标不可达）
    #>
    param([string]$Url)
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 8000
        $req.ReadWriteTimeout = 8000
        $req.Proxy = $null
        # 部分 BRAS 只劫持浏览器 UA 的请求，探测也要伪装成浏览器
        $req.UserAgent = (Get-BrowserUserAgent)
        $req.Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        $resp = $req.GetResponse()
        return (Resolve-ProbeResponse -Response $resp -Url $Url)
    } catch [System.Net.WebException] {
        # AllowAutoRedirect=false 时 4xx/5xx 会抛异常，但响应体里可能正是认证页
        $resp = $_.Exception.Response
        if (-not $resp) {
            return @{ Status = 'fail'; Location = '' }
        }
        return (Resolve-ProbeResponse -Response $resp -Url $Url)
    } catch {
        return @{ Status = 'fail'; Location = '' }
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }
}

function Get-NetworkStatus {
    <#
        判断当前网络状态。
        返回 @{Status='online'|'captive'|'offline'; PortalUrl='认证入口URL'}
        - online: 能正常访问外网
        - captive: HTTP 被 BRAS 劫持到认证页，需要认证（PortalUrl 可能为空）
        - offline: 连接失败，无网络
    #>
    param([string]$CaptiveUrl, [string]$FallbackUrl)
    foreach ($url in @($CaptiveUrl, $FallbackUrl)) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $r = Http-Probe -Url $url
        if ($r.Status -eq 'ok') {
            return @{ Status = 'online'; PortalUrl = '' }
        }
        if ($r.Status -eq 'captive') {
            return @{ Status = 'captive'; PortalUrl = $r.Location }
        }
        # fail: 尝试下一个探测地址
    }
    return @{ Status = 'offline'; PortalUrl = '' }
}

# ---------- 认证 ----------
function Get-QueryParams {
    param([string]$Url)
    $dict = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Url)) { return $dict }
    try {
        $u = [System.Uri]$Url
        $qs = [System.Web.HttpUtility]::ParseQueryString($u.Query)
    } catch {
        return $dict
    }
    foreach ($k in $qs.AllKeys) {
        if ($k) { $dict[$k] = $qs[$k] }
    }
    return $dict
}

function Get-PortalParamsFromServer {
    <#
        兜底：直接 GET portal.do，从返回页面里提取认证参数。
        用于劫持响应里提不出完整 portal URL（参数为空）的场景。
        拿不到返回 $null，绝不返回残缺参数。
    #>
    param([string]$PortalBase)
    $url = "$PortalBase/portal.do"
    $resp = $null
    $body = ''
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'GET'
        $req.Timeout = 8000
        $req.ReadWriteTimeout = 8000
        $req.Proxy = $null
        $req.UserAgent = (Get-BrowserUserAgent)
        $resp = $req.GetResponse()
        $body = Read-ResponseBody -Response $resp -MaxChars 65536
    } catch {
        Write-Log "兜底拉取 portal.do 失败: $($_.Exception.Message)" 'WARN'
        return $null
    } finally {
        if ($resp) { try { $resp.Close() } catch { } }
    }

    $p = Extract-PortalUrl -Body $body
    if ($p) {
        Write-Log "从 portal.do 页面提取到认证入口: $p"
        return (Get-QueryParams -Url $p)
    }
    # 页面里可能只内嵌了 query 片段，没有完整 URL
    if ($body -match 'wlanuserip=[^"''<>\s]*') {
        $fragment = $Matches[0]
        Write-Log "从 portal.do 页面提取到参数片段（$fragment）"
        return (Get-QueryParams -Url "http://portal.local/portal.do?$fragment")
    }
    Write-Log "portal.do 页面未包含可用认证参数（响应长度 $($body.Length)）" 'WARN'
    return $null
}

function Submit-QuickAuth {
    <#
        向 Portal 服务器 GET /quickauth.do 提交认证。
        返回服务器 JSON 对象。
    #>
    param(
        [string]$PortalBase,
        [string]$Path,
        [System.Collections.IDictionary]$Params
    )
    $query = ($Params.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f [System.Uri]::EscapeDataString([string]$_.Key), [System.Uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    $url = "$PortalBase$Path`?$query"

    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'
    $req.Timeout = 10000
    $req.ReadWriteTimeout = 10000
    $req.Proxy = $null
    $req.Accept = 'application/json, text/javascript, */*; q=0.01'
    $req.Referer = $PortalBase + '/portal.do'
    $req.UserAgent = (Get-BrowserUserAgent)

    try {
        $resp = $req.GetResponse()
        $body = Read-ResponseBody -Response $resp -MaxChars 65536
        $resp.Close()
        Write-Log "quickauth.do response: $body"
        try {
            $jsonText = $body.Trim()
            # 部分 portal 返回 JSONP：cb({...}) 或 cb({...});
            if ($jsonText -match '(?s)^\s*[\w$.]+\s*\((.*)\)\s*;?\s*$') {
                $jsonText = $Matches[1]
            }
            return ($jsonText | ConvertFrom-Json)
        } catch {
            Write-Log "响应不是合法 JSON: $body" 'WARN'
            return $null
        }
    } catch {
        Write-Log "quickauth.do 请求异常: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

function Test-AuthSuccess {
    <#
        判定 quickauth.do 的返回是否代表"已认证"。
        code=0 是成功；部分部署对"终端已在线"返回非 0 码，这类情况也算成功，
        否则会误判失败并反复重试。
    #>
    param($Json)
    if (-not $Json) { return $false }
    if ("$($Json.code)" -eq '0') { return $true }
    $msg = "$($Json.message)"
    if ($msg -match '已在线|already\s*(logged|online)|ip\s*已?在线') { return $true }
    return $false
}

# ---------- 主流程 ----------
try {
    Add-Type -AssemblyName System.Web

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        # 此时 LogFile 已指向默认路径，这条错误一定能落盘
        Write-Log "配置文件不存在: $ConfigPath" 'ERROR'
        exit 1
    }

    $cfg = Read-Ini -Path $ConfigPath
    Initialize-Log -Path (Join-Path $scriptDir $cfg['Settings']['LogFile'])

    $username = $cfg['Auth']['Username']
    $password = $cfg['Auth']['Password']
    $suffix   = $cfg['Auth']['Suffix']
    $pingHost = $cfg['Network']['PingHost']
    $captive  = $cfg['Network']['CaptiveUrl']
    $portalBase = $cfg['Network']['PortalBase']
    $quickAuth  = $cfg['Network']['QuickAuthPath']
    $fallback   = $cfg['Network']['FallbackUrl']
    $ssid       = $cfg['Network']['Ssid']
    if ([string]::IsNullOrWhiteSpace($ssid)) { $ssid = 'HTU_Student' }

    $retryWait  = Get-ConfigInt -Ini $cfg -Section 'Settings' -Key 'RetryInterval' -Default 5
    $maxRetries = Get-ConfigInt -Ini $cfg -Section 'Settings' -Key 'MaxRetries' -Default 3
    $heartbeatMinutes = Get-ConfigInt -Ini $cfg -Section 'Settings' -Key 'HeartbeatMinutes' -Default 30
    $probeInterval    = Get-ConfigInt -Ini $cfg -Section 'Settings' -Key 'ProbeIntervalMinutes' -Default 1
    # 日志模式: heartbeat=在线时按心跳间隔写日志(防刷屏); normal=每次探测都写一条
    $logMode = [string]$cfg['Settings']['LogMode']
    if ($logMode -ne 'normal') { $logMode = 'heartbeat' }
    $probeStamp = Join-Path $env:TEMP 'campus_probe.ts'

    # 必填项校验：缺项时明确报错，避免拿着空地址空转
    if ([string]::IsNullOrWhiteSpace($portalBase) -or [string]::IsNullOrWhiteSpace($quickAuth) -or
        [string]::IsNullOrWhiteSpace($captive)) {
        Write-Log "config.ini 缺少 [Network] 必填项（CaptiveUrl / PortalBase / QuickAuthPath）" 'ERROR'
        exit 1
    }
    if ($password -eq 'YOUR_PASSWORD_HERE' -or [string]::IsNullOrWhiteSpace($password)) {
        Write-Log "密码仍为占位符，请先编辑 config.ini 填入真实校园网密码" 'ERROR'
        exit 2
    }
    # 任务计划的 ExecutionTimeLimit 是 5 分钟，重试预算过大会被中途强杀
    if (($maxRetries * $retryWait) -gt 240) {
        Write-Log "重试预算 ${maxRetries}×${retryWait}s 偏大，可能被任务计划 5 分钟时限强杀，建议调小 MaxRetries 或 RetryInterval" 'WARN'
    }

    # 0. 探测间隔检查：未到间隔则静默跳过本次触发（任务计划仍每分钟触发，脚本自行节流）
    if ($probeInterval -gt 0) {
        $lastProbe = Read-TimestampFile -Path $probeStamp
        if ($lastProbe -and ((Get-Date) - $lastProbe).TotalMinutes -lt $probeInterval) {
            exit 0
        }
    }

    # 1. HTTP 探测判断网络状态（ping 不可靠：校园网 BRAS 放行 ICMP 但拦截 HTTP，ping 通不代表已认证）
    $ns = Get-NetworkStatus -CaptiveUrl $captive -FallbackUrl $fallback

    if ($ns.Status -eq 'online') {
        $shouldLog = $true
        $now = Get-Date
        if ($logMode -eq 'heartbeat') {
            # 心跳模式：按 HeartbeatMinutes 间隔写一条，避免刷爆日志
            $heartbeatFile = Join-Path $env:TEMP 'campus_heartbeat.ts'
            $lastHeartbeat = Read-TimestampFile -Path $heartbeatFile
            if ($lastHeartbeat -and ($now - $lastHeartbeat).TotalMinutes -lt $heartbeatMinutes) {
                $shouldLog = $false
            }
        }
        if ($shouldLog) {
            $modeNote = if ($logMode -eq 'normal') { '（normal 模式每次记录）' } else { '' }
            Write-Log "外网可达（HTTP 探测通过），无需认证。$modeNote"
            if ($logMode -eq 'heartbeat') {
                Write-TimestampFile -Path $heartbeatFile
            }
        }
        # 在线，记录本次探测时间（供探测间隔抑制用）
        Write-TimestampFile -Path $probeStamp
        exit 0
    }

    if ($ns.Status -eq 'offline') {
        $pingOk = [bool](Test-Connection -ComputerName $pingHost -Count 1 -Quiet -ErrorAction SilentlyContinue)
        Write-Log "HTTP 探测失败，疑似无网络连接（WiFi 未连接或 DHCP 未完成）。ping $pingHost 辅助结果: $pingOk。本次退出，等待下次任务。" 'WARN'
        exit 0
    }

    # captive：未认证，HTTP 被 BRAS 劫持到认证页
    Write-Log "检测到未认证（HTTP 被劫持到认证页），开始自动认证..."
    $portalUrl = $ns.PortalUrl
    if ($portalUrl) {
        Write-Log "捕获到 Portal 跳转: $portalUrl"
    } else {
        Write-Log "已确认未认证，但未能从劫持响应中提取 Portal URL，改为直接拉取 portal.do" 'WARN'
    }

    # 3. 解析参数（wlanuserip/wlanacname/mac/vlan 等）
    $params = Get-QueryParams -Url $portalUrl
    $hasSessionParams = $params.Contains('wlanuserip') -or $params.Contains('wlanacname') -or $params.Contains('mac')

    if (-not $hasSessionParams) {
        # 兜底：主动拉一次 portal.do。不能拿探测地址顶替，否则参数为空、认证必然失败
        Write-Log "认证参数缺失，尝试从 $portalBase/portal.do 兜底获取..." 'WARN'
        $fb = Get-PortalParamsFromServer -PortalBase $portalBase
        if ($fb) {
            foreach ($k in $fb.Keys) { $params[$k] = $fb[$k] }
            $hasSessionParams = $params.Contains('wlanuserip') -or $params.Contains('wlanacname') -or $params.Contains('mac')
        }
    }

    if (-not $hasSessionParams) {
        Write-Log "无法获取 wlanuserip/wlanacname/mac 等必要参数，本次不提交残缺认证请求。等待下次任务触发。" 'ERROR'
        exit 3
    }

    # 补充认证参数
    $params['userid'] = $username + $suffix
    $params['passwd'] = $password
    if (-not $params.Contains('ssid')) { $params['ssid'] = $ssid }

    # 4. 重试提交
    $ok = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-Log "第 $i/$maxRetries 次提交 quickauth.do ..."
        $json = Submit-QuickAuth -PortalBase $portalBase -Path $quickAuth -Params $params
        if (Test-AuthSuccess -Json $json) {
            $msg = if ($json.message) { $json.message } else { 'ok' }
            Write-Log "认证成功！message=$msg"
            $ok = $true
            break
        }
        if ($json) {
            Write-Log "认证未成功（code=$($json.code) message=$($json.message)），${retryWait}s 后重试。" 'WARN'
        } else {
            Write-Log "认证未成功（无有效响应），${retryWait}s 后重试。" 'WARN'
        }
        Start-Sleep -Seconds $retryWait
    }

    if (-not $ok) {
        Write-Log "达到最大重试次数，本次认证失败。等待下次任务触发。" 'ERROR'
        exit 3
    }

    # 5. 认证后验证
    Start-Sleep -Seconds 3
    $verify = Get-NetworkStatus -CaptiveUrl $captive -FallbackUrl $fallback
    if ($verify.Status -eq 'online') {
        Write-Log "认证后外网恢复，任务完成。"
        # 认证成功，记录本次探测时间（供探测间隔抑制用）
        Write-TimestampFile -Path $probeStamp
    } else {
        Write-Log "认证返回成功但 HTTP 探测仍不通（$($verify.Status)），可能需要更长时间生效，下次任务再验证。" 'WARN'
    }
    exit 0

} catch {
    Write-Log "未处理异常: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    exit 99
}
