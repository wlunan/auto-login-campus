#requires -Version 5.1
<#
.SYNOPSIS
    回归测试：验证 auto_login.ps1 里 WiFi 自动连接相关的 netsh 输出解析。
.DESCRIPTION
    只测纯解析函数（ConvertFrom-WlanInterfaceOutput / ConvertFrom-WlanNetworksOutput /
    ConvertFrom-WlanProfilesOutput），用固定的 netsh 文本喂入，因此：
      - 不需要真的连着校园网，也不需要无线网卡
      - 不会真的发起连接、不改系统状态
    覆盖英文/中文两种 netsh 输出，以及"相似 SSID 不能误判"这个最容易踩的坑。
.USAGE
    powershell -ExecutionPolicy Bypass -File scripts\tests\test_wifi_autoconnect.ps1
#>

$scriptPath = Join-Path $PSScriptRoot '..\auto_login.ps1'

$tokens = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$err)
if ($err -and $err.Count -gt 0) {
    Write-Host '脚本语法错误，无法测试:' -ForegroundColor Red
    $err | ForEach-Object { Write-Host $_.Message }
    exit 1
}
$funcAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcAsts) { Invoke-Expression $f.Extent.Text }
Write-Host "已从 auto_login.ps1 加载 $($funcAsts.Count) 个函数（与正式版同源码）"

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Cond)
    if ($Cond) { $script:pass++; Write-Host "[PASS] $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "[FAIL] $Name" -ForegroundColor Red }
}

# ---------- 样例：netsh wlan show interfaces ----------
$ifEnConnected = @'
There is 1 interface on the system:

    Name                   : WLAN
    Description            : Intel(R) Wi-Fi 6 AX201 160MHz
    State                  : connected
    SSID                   : HTU_Student
    BSSID                  : 11:22:33:44:55:66
'@

$ifEnDisconnected = @'
There is 1 interface on the system:

    Name                   : WLAN
    Description            : Intel(R) Wi-Fi 6 AX201 160MHz
    State                  : disconnected
    Radio status           : Hardware On
'@

$ifZhConnected = @'
系统上有 1 个接口:

    名称                   : WLAN
    描述                   : Intel(R) Wi-Fi 6 AX201 160MHz
    状态                   : 已连接
    SSID                   : HTU_Student
    BSSID                  : 11:22:33:44:55:66
    信号                   : 80%
'@

# ---------- 样例：netsh wlan show networks ----------
$networksEn = @'
Interface name : WLAN

There are 2 networks currently visible.

SSID 1 :
    Network type            : Infrastructure

SSID 2 : HTU_Teacher
    Network type            : Infrastructure

SSID 3 : HTU_Student
    Network type            : Infrastructure
'@

$networksZh = @'
接口名称 : WLAN

当前有 1 个网络可见。

SSID 1 : HTU_Student
    网络类型            : 结构
    身份验证            : 开放
'@

# ---------- 样例：netsh wlan show profiles ----------
$profilesEn = @'
Profiles on interface WLAN:

User profiles
-------------
    All User Profile     : HTU_Student
    All User Profile     : Redmi K70 Ultra
'@

$profilesZh = @'
接口 WLAN 上的配置文件:

用户配置文件
-------------
    所有用户配置文件 : HTU_Student
    所有用户配置文件 : Tenda_888_5G
'@

$profilesSpecial = @'
用户配置文件
-------------
    所有用户配置文件 : Mi-Setup<76>All-in-One Inkjet
'@

# ---------- 用例：接口状态解析 ----------
$s1 = ConvertFrom-WlanInterfaceOutput -Text $ifEnConnected
Check "英文已连接 → Connected=true (实际: $($s1.Connected))" ($s1.Connected)
Check "英文已连接 → SSID 取到 HTU_Student 而非 BSSID (实际: $($s1.Ssid))" ($s1.Ssid -eq 'HTU_Student')

$s2 = ConvertFrom-WlanInterfaceOutput -Text $ifEnDisconnected
Check "英文未连接 → Connected=false (实际: $($s2.Connected))" (-not $s2.Connected)
Check "英文未连接 → State=disconnected (实际: $($s2.State))" ($s2.State -eq 'disconnected')

$s3 = ConvertFrom-WlanInterfaceOutput -Text $ifZhConnected
Check "中文已连接 → Connected=true (实际: $($s3.Connected))" ($s3.Connected)
Check "中文已连接 → SSID 正确 (实际: $($s3.Ssid))" ($s3.Ssid -eq 'HTU_Student')
Check "中文已连接 → State=已连接 (实际: $($s3.State))" ($s3.State -eq '已连接')

Check '空文本 → Connected=false' (-not (ConvertFrom-WlanInterfaceOutput -Text '').Connected)

# ---------- 用例：扫描列表 ----------
Check '扫描列表含目标 SSID → true' (ConvertFrom-WlanNetworksOutput -Text $networksEn -Ssid 'HTU_Student')
Check '中文扫描列表含目标 SSID → true' (ConvertFrom-WlanNetworksOutput -Text $networksZh -Ssid 'HTU_Student')
Check '目标 SSID 只是可见 SSID 的前缀 → false（必须全等）' (-not (ConvertFrom-WlanNetworksOutput -Text $networksEn -Ssid 'HTU_Stude'))
Check '无 SSID 名（隐藏网络）→ 不匹配空查询' (-not (ConvertFrom-WlanNetworksOutput -Text $networksEn -Ssid ''))

# ---------- 用例：配置文件 ----------
Check '英文配置文件列表含目标 → true' (ConvertFrom-WlanProfilesOutput -Text $profilesEn -Ssid 'HTU_Student')
Check '中文配置文件列表含目标 → true' (ConvertFrom-WlanProfilesOutput -Text $profilesZh -Ssid 'HTU_Student')
Check '配置文件不含目标 → false' (-not (ConvertFrom-WlanProfilesOutput -Text $profilesEn -Ssid 'HTU_Teacher'))
Check 'SSID 含正则特殊字符也能精确匹配' (ConvertFrom-WlanProfilesOutput -Text $profilesSpecial -Ssid 'Mi-Setup<76>All-in-One Inkjet')
Check 'SSID 含特殊字符时不匹配其前缀' (-not (ConvertFrom-WlanProfilesOutput -Text $profilesSpecial -Ssid 'Mi-Setup'))

Write-Host "`n===== 结果: $pass 通过, $fail 失败 ====="
if ($fail -gt 0) { exit 1 } else { exit 0 }
