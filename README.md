# 河南师范大学校园网自动连接方案


## 项目目标

办公室工位电脑（某品牌笔记本，Windows 11）连接 HTU_Student 校园网，在以下场景下自动恢复网络和远程控制（GameViewer），无需到现场：

- 电脑重启 / 断电恢复
- 校园网认证过期 / 被踢下线
- 突然断网后恢复

## 方案概览

采用**电脑端保底方案（方案A）**，不刷路由器、不改 BIOS：

1. **GameViewer 远程服务**已配置为 LocalSystem 自动启动（现状），Windows 账号无密码开机自动登录，保证网络通了就能被远程连上。
2. **自动认证脚本** `scripts/auto_login.ps1`：
   - 每 1 分钟 HTTP 探测外网（`1.1.1.1`，**不用 ping**：BRAS 放行 ICMP 但拦截 HTTP，ping 通不代表已认证）
   - 被劫持时自动捕获 Portal 跳转，向 `http://10.101.2.194:6060/quickauth.do` 提交账号密码
   - **WiFi 层兜底**：探测到完全断网时，若当前没连校园网 WiFi 但能扫到、且系统已保存该 WiFi 的配置文件，先 `netsh wlan connect` 连上再继续认证（同一次运行内完成，不必等下一轮）
   - 失败重试、写日志、绕开系统代理、日志超 5MB 自动归档
3. **Windows 任务计划** `CampusAutoLogin`（当前启用方案）：
   - 主体 SYSTEM，安装后 30 秒开始、每 1 分钟执行一次；重启后同样 30 秒接续
   - 不依赖用户登录
   - 安装：管理员运行 `install_task.ps1`，或双击 `run_install_admin.bat`（自提权）

> 备用方案：`scripts/keepalive_loop.ps1` + 启动文件夹快捷方式（免管理员）。
> 曾在任务计划无法安装时使用，任务计划安装成功后已停用，脚本保留备用。

## 目录结构

```
auto-login-campus/
├── README.md                    # 本文件
├── .gitignore
├── scripts/
│   ├── config.ini               # 配置（账号密码，密码需手动填写，git 忽略）
│   ├── config.example.ini       # 配置模板（提交用，密码为占位符）
│   ├── auto_login.ps1           # 主认证脚本
│   ├── install_task.ps1         # 安装任务计划（需管理员）
│   ├── uninstall_task.ps1       # 卸载任务计划（回滚）
│   ├── keepalive_loop.ps1       # 备用：启动文件夹守护循环（免管理员，已停用）
│   ├── run_install_admin.bat    # 一键安装入口（自提权）
│   └── tests/
│       ├── test_captive_detection.ps1   # 探测逻辑回归测试
│       ├── test_wifi_autoconnect.ps1    # WiFi 自动连接解析回归测试
│       └── test_install_verdict.ps1     # 安装结果判定（0/2 退出码）回归测试
├── docs/
│   ├── 01-现状报告.md
│   ├── 02-方案设计.md
│   ├── 03-操作记录.md
│   ├── 04-回滚步骤.md
│   └── 05-原理说明.md            # 系统原理与认证流程详解
└── logs/
    ├── auto_login.log           # 运行日志（git 忽略）
    ├── install_task.log         # 安装日志（git 忽略）
    └── install_stdout.txt       # 提权安装的控制台输出（git 忽略）
```

## 快速开始

### 1. 准备配置文件并填写账号密码（必做，先做这步）

仓库里只有模板 `scripts/config.example.ini`，`config.ini` 被 git 忽略、需要你自己创建。复制一份再改：

```powershell
cd E:\06DateClass\auto-login-campus\scripts
Copy-Item .\config.example.ini .\config.ini
```

然后编辑 `scripts\config.ini`，至少确认/修改这两项：

| 配置项                     | 说明                                                                              |
| -------------------------- | --------------------------------------------------------------------------------- |
| `Password`（`[Auth]`） | 把 `YOUR_PASSWORD_HERE` 改成你的真实校园网密码，**不改会直接 `exit 2`** |
| `Username` / `Suffix`  | 学号与账号后缀（学生 `@htu`，教职工 `@htu.edu.cn`）                           |

> 跳过这一步直接安装任务计划，任务只会每分钟失败一次并写 `config.ini 不存在` 的 WARN，日志里拿不到任何认证结果。

### 2. 安装任务计划（需要管理员）

方式一，双击 `scripts\run_install_admin.bat`：会自动弹 UAC 提权；提权后在新窗口里跑完安装，并把**完整安装输出回显在窗口**（同时存档到 `logs\install_stdout.txt`），窗口最后一行会给结论。

方式二，右键「以管理员身份运行」PowerShell，执行：

```powershell
cd E:\06DateClass\auto-login-campus\scripts
.\install_task.ps1
```

两种方式都以退出码表明结果：

| 退出码 | 含义 | 窗口/输出里的标志 |
| --- | --- | --- |
| `0` | 完全成功：任务已启用、下次运行时间在未来 | `===== 结论: 安装成功 ... =====` |
| `2` | 任务已注册但需人工核对（触发器未生效 / 状态非 Ready / 读不到任务信息） | `===== 结论: ... 有 N 项需要人工核对 =====` + 每项 `!` 原因 |
| `1` | 注册失败，什么都没装（如 `0x80070005` 权限不足、`0x80041318` XML 越界） | `注册任务失败: ...` |

关键校验仍是「下次运行时间」必须是未来时间——脚本会打印 `触发器生效，任务已排定在 ... 自动运行`。**看到 `结论: 安装成功` 才叫成功，不要只看有没有报错。**

> 注册后脚本会最多等 20 秒让任务计划服务刷新下次运行时间（注册+立刻触发测试运行时，直接读常常读到空值，属服务端延迟，不是触发器坏了）。
> 若仍报 `下次运行时间: （等待 20s 仍未刷新）` 并 `exit 2`：先**原样再跑一次安装脚本**（多数情况下第二次就正常），依旧不行再按提示去任务计划程序看触发器。


### 3. 查看日志

```powershell
Get-Content E:\06DateClass\auto-login-campus\logs\auto_login.log -Tail 20 -Wait
```

### 4. 可调配置（改 `scripts\config.ini`，改完下一分钟自动生效，无需重装）

| 配置项                                  | 默认            | 说明                                                                      |
| --------------------------------------- | --------------- | ------------------------------------------------------------------------- |
| `ProbeIntervalMinutes`                | `1`           | 探测间隔（分钟）。`1`=每分钟，`5`=每5分钟，`0`=任务每次触发都探测   |
| `LogMode`                             | `normal`      | `normal`=每次探测写一条日志；`heartbeat`=在线时按心跳间隔写（防刷屏） |
| `HeartbeatMinutes`                    | `30`          | 仅 heartbeat 模式生效：在线时多少分钟写一条心跳                           |
| `RetryInterval` / `MaxRetries`      | `5` / `3`   | 单次认证失败后的重试间隔（秒）与最多重试次数                              |
| `Ssid`（`[Network]`）               | `HTU_Student` | 提交认证时上报的 SSID，换校区/换 SSID 时改这里，无需改代码                |
| `AutoConnectWifi`（`[Network]`）    | `true`        | 断网时若没连校园网但能扫到，是否自动连接（`false` 只认证不碰 WiFi）     |
| `WifiConnectTimeout`（`[Network]`） | `30`          | 发起连接后等待关联完成的最长秒数                                          |
| `WifiRetryMinutes`（`[Network]`）   | `5`           | 自动连接失败后的冷却分钟数，避免每分钟反复重连（`0`=不冷却）            |

> 说明：任务计划本身保持每 1 分钟触发一次，脚本读 `ProbeIntervalMinutes` 自行节流——未到间隔的运行会静默跳过，不占资源。
>
> ⚠️ 如果你把 `ProbeIntervalMinutes` 调大了（例如 `30`），断网后的恢复时间和测试等待时间都同比例变长。**抓「断网自动重认证」时必须先临时改回 `1`**，否则会误以为脚本没跑。
> `Ssid` 项缺失或留空时，脚本按 `HTU_Student` 处理。

## 测试验收（怎么测）

> ⚠️ **场景 1/2/3/4 的前提：测试时电脑必须连的是校园网 `HTU_Student`，绝不能是手机热点！**
> 手机热点（如 Redmi K70 Ultra）网络里，校园网认证服务器 `10.101.2.194` 根本不可达，脚本无法认证。
> 确认方法：运行 `netsh wlan show interfaces`，看 `SSID` 那行是不是 `HTU_Student`。
> 若电脑断开校园网后自动连了手机热点，手动切回：
>
> ```powershell
> netsh wlan connect name="HTU_Student" ssid="HTU_Student"
> ```
>
> **例外是场景 5（未连接 WiFi 时自动连接）——那条必须故意断开校园网**。测它时把手机热点关掉，否则电脑可能先连上热点、脚本判定"在线"就不会去连校园网了。
>
> ⚠️ 反向影响：加了 WiFi 自动连接后，场景 1 里你手动断开 `HTU_Student`，脚本可能**先把 WiFi 自己连回来**再认证（这是新行为，不是异常）。想纯手工复现"断开→重连"，测试前临时把 `config.ini` 里 `AutoConnectWifi` 设为 `false`，测完改回。

### 场景 1：断网自动重认证（最常用）

1. 确认当前连的是 `HTU_Student`（见上方前提）
2. 打开日志实时窗口：
   ```powershell
   Get-Content E:\06DateClass\auto-login-campus\logs\auto_login.log -Tail 30 -Wait
   ```
3. 点右下角 WiFi → **断开 `HTU_Student`**
4. 等 10 秒，**重新连接 `HTU_Student`**（连的时候看清 SSID，别连成手机热点）
5. 观察日志，**1 分钟内**（`ProbeIntervalMinutes=1` 时；调大过就按该间隔等）应依次出现：
   ```
   [INFO] 检测到未认证（HTTP 被劫持到认证页），开始自动认证...
   [INFO] 捕获到 Portal 跳转: http://10.101.2.194:6060/portal.do?...
   [INFO] 第 1/3 次提交 quickauth.do ...
   [INFO] 认证成功！message=...
   ```
6. 验证：能打开网页 + 用另一台设备通过 GameViewer 能连上这台电脑

### 场景 2：重启电脑

1. 重启电脑
2. 开机后自动进桌面（账号无密码），任务计划由开机触发器在 30 秒后接续，每 1 分钟检测（首次安装则是安装后 30 秒立即开始，不必等重启）
3. 等 1~2 分钟，用另一台设备通过 GameViewer 连接
4. 判断标准：远端能连上 = 通过；连不上就查日志

### 场景 3：认证过期（可选）

1. 浏览器打开认证页 `http://10.101.2.194:6060/portal.do`，找到"注销/下线"按钮点掉
2. 或等校园网自然踢下线
3. 观察日志是否在 `ProbeIntervalMinutes` 个间隔内自动重新认证（默认 1 分钟）

### 场景 4：手动主动执行（不用等任务计划）

脚本不依赖任务计划，可以随时手工跑一次。典型用途：**Wi-Fi 已连上 `HTU_Student` 但尚未认证**，想立刻验证一次真实登录，不必断开重连或干等 1 分钟。

```powershell
cd E:\06DateClass\auto-login-campus\scripts
powershell -NoProfile -ExecutionPolicy Bypass -File .\auto_login.ps1
"exit=$LASTEXITCODE"
Get-Content E:\06DateClass\auto-login-campus\logs\auto_login.log -Tail 30
```

⚠️ **必须用 `-File` 方式运行**，不要复制代码粘贴到控制台、也不要点号加载（`. .\auto_login.ps1`）。脚本靠 `$PSScriptRoot` 定位 `config.ini` 和日志目录，只有 `-File` 才会正确赋值；点号加载会直接执行整个主流程。

#### 手动跑"看起来没反应"的三个正常原因

1. **脚本从不往控制台打印** —— 全文只有 `Write-Log` 写文件，终端空白是正常的，必须看日志文件。
2. **可能被探测节流静默跳过**（`ProbeIntervalMinutes=1`）—— 跳过时不写任何日志、直接 `exit 0`。
3. **`exit 0` 有歧义** —— 既表示"认证成功"，也表示"本来就在线""无网络提前退出""被节流跳过"。

第 2 点补充：SYSTEM 任务的戳在 `C:\Windows\Temp`，你手动跑用的是 `C:\Users\<你>\AppData\Local\Temp`，**两套互不干扰**，所以任务计划刚跑过不会挡住你测试；但你自己连续跑两次，第二次会被上一次挡住。保险起见先清一次：

```powershell
Remove-Item "$env:TEMP\campus_probe.ts","$env:TEMP\campus_heartbeat.ts" -Force -ErrorAction SilentlyContinue
```

真正有区分度的是其余退出码：

| 退出码 | 含义                                             |
| ------ | ------------------------------------------------ |
| `0`  | 在线无需认证 / 认证成功 / offline 提前退出       |
| `1`  | `config.ini` 不存在或缺少 `[Network]` 必填项 |
| `2`  | 密码仍是 `YOUR_PASSWORD_HERE` 占位符           |
| `3`  | 认证失败（重试次数耗尽）                         |
| `99` | 未处理异常                                       |

判断成功应以日志出现 `认证成功！message=...` 为准，不能只看退出码。

#### 只测探测判定、不提交认证

想先确认"能不能正确识别出被劫持"，而不想真的登进去。注意**不能点号加载**（会执行主流程），正确做法是从源码里只提取函数定义：

```powershell
$p = 'E:\06DateClass\auto-login-campus\scripts\auto_login.ps1'
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$t, [ref]$e)
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

Get-NetworkStatus -CaptiveUrl 'http://1.1.1.1' -FallbackUrl 'http://www.msftconnecttest.com/connecttest.txt'
Http-Probe -Url 'http://1.1.1.1'
```

未认证状态下应返回 `Status = captive`，且 `PortalUrl` 是那串 `portal.do?wlanuserip=...`。这一步验证的是最脆弱的部分（劫持识别 + URL 提取），且完全不碰账号密码。

#### 测失败路径（不动真实配置）

用 `-ConfigPath` 指向一份密码故意写错的副本，可完整验证"重试 3 次 → 写 WARN → `exit 3`"的链路（约 15 秒）：

```powershell
Copy-Item .\config.ini .\config.test.ini
# 把 config.test.ini 里的 Password 改成错的
powershell -NoProfile -ExecutionPolicy Bypass -File .\auto_login.ps1 -ConfigPath .\config.test.ini
```

测完删除 `config.test.ini`，避免误提交。

> 手动执行是安全的：不会重新注册任务计划、不改任何系统状态。唯一副作用是认证成功后会写一次 `$probeStamp`，最多让 SYSTEM 任务下次触发延后 1 分钟，无害。
> 但手动跑成功只证明协议链路通，**不等于 SYSTEM 上下文也通**。最终验收仍应执行下面这条，再核对日志：
>
> ```powershell
> Start-ScheduledTask -TaskName CampusAutoLogin   # 需管理员
> ```

### 场景 5：未连接校园网 WiFi（自动连接）

前提（缺一不可，脚本不猜密码、不新建配置）：

1. 这台电脑**以前手动连过** `HTU_Student`，系统里已有该 WiFi 的配置文件（`netsh wlan show profiles` 能看到 `All User Profile : HTU_Student`）
2. 那个 SSID **在扫描范围内**（`netsh wlan show networks` 能看到）
3. 无线网卡开着、WLAN 服务在跑

测试步骤：

1. 先做三项只读确认（不通过就别急着测，脚本也不会做任何猜测）：
   ```powershell
   netsh wlan show interfaces   # State 应为 disconnected 或连的是别的 WiFi
   netsh wlan show networks     # 应能看到 SSID x : HTU_Student
   netsh wlan show profiles     # 应有 All User Profile : HTU_Student
   ```
2. 清掉上一次尝试留下的冷却戳，否则 5 分钟内会被静默跳过（手动跑的戳在用户 TEMP，与 SYSTEM 任务互不干扰）：
   ```powershell
   Remove-Item "$env:TEMP\campus_wifi.ts","$env:TEMP\campus_probe.ts" -Force -ErrorAction SilentlyContinue
   ```
3. 点右下角 WiFi → **断开** 当前网络（或直接连手机热点再关掉热点）
4. 盯日志：
   ```powershell
   Get-Content E:\06DateClass\auto-login-campus\logs\auto_login.log -Tail 20 -Wait
   ```
5. 下一个探测周期内应依次出现：
   ```
   [INFO] 检测到 WiFi「HTU_Student」在覆盖范围内（当前未连接无线网络），尝试自动连接...
   [INFO] netsh wlan connect 返回: 已成功连接到此请求的配置文件...
   [INFO] 已关联 WiFi「HTU_Student」，等待 DHCP 与 Portal 探测
   [INFO] 检测到未认证（HTTP 被劫持到认证页），开始自动认证...
   [INFO] 认证成功！message=...
   ```

   连上 WiFi 后是同一次运行内接着认证，不用等下一分钟。

失败时的日志含义：

| 日志                                            | 原因                             | 处理                                             |
| ----------------------------------------------- | -------------------------------- | ------------------------------------------------ |
| `未保存 WiFi「HTU_Student」的配置文件`        | 系统没有该 WiFi 的 profile       | 手动连一次并勾选"自动连接"                       |
| `当前扫描不到 WiFi「HTU_Student」`            | 不在覆盖范围 / 网卡关闭          | 走到范围内；任务下次触发会再试                   |
| `连接 WiFi「HTU_Student」在 30s 内未完成关联` | 关联慢 / 密码错 / 信号差         | 冷却 5 分钟后重试，可调大 `WifiConnectTimeout` |
| `HTTP 探测失败，但已连接 WiFi「HTU_Student」` | 已连上但 DHCP 未就绪，不重复连接 | 等下一轮即可                                     |

### 判断标准（三个都满足 = 通过）

- 日志出现 `认证成功！`
- 浏览器能正常打开网页
- 远端设备 GameViewer 能连上电脑

场景 5 另加一条（四个都满足 = 通过）：

- 日志出现 `已关联 WiFi「HTU_Student」`，且随后出现 `认证成功！`（只关联成功不算通过，必须连上并认证）

> 场景 5 的两个坑：①手动跑（用户会话）成功**不等于** SYSTEM 任务也成功，最终仍要用 `Start-ScheduledTask -TaskName CampusAutoLogin` 复验；②刚装完任务先重跑一次 `run_install_admin.bat`，否则任务里还留着 `-RunOnlyIfNetworkAvailable`，全断网时根本不会启动。

校园网未认证时有**两类劫持表现**：3xx 跳转到认证页，或直接返回 200/403 + 认证页 HTML（深澜透明劫持；部分 BRAS 用 403 承载认证页）。脚本对两类都识别——只要响应里出现 `portal.do` / `quickauth` / `wlanuserip` 特征，就判定未认证并自动提交；若提不出参数，会主动 GET `portal.do` 兜底，拿不到必要参数则明确报错而不是硬提交。可先跑回归测试确认探测逻辑正常：

```powershell
powershell -ExecutionPolicy Bypass -File E:\06DateClass\auto-login-campus\scripts\tests\test_captive_detection.ps1
powershell -ExecutionPolicy Bypass -File E:\06DateClass\auto-login-campus\scripts\tests\test_wifi_autoconnect.ps1
powershell -ExecutionPolicy Bypass -File E:\06DateClass\auto-login-campus\scripts\tests\test_install_verdict.ps1
```

预期输出依次为 `11 通过, 0 失败`、`17 通过, 0 失败`、`13 通过, 0 失败`（后两者只喂固定文本，不需要真连 WiFi、也不需要管理员）。

### 注意事项

- 日志在 `LogMode=heartbeat` 下在线时 30 分钟才写一条心跳（防刷屏），默认 `normal` 每次探测都写一条；**断网瞬间一定会写详细日志**，所以盯日志要在"断开 WiFi 后立刻"看
- 日志超过 5MB 会自动归档为 `auto_login.log.1`（只保留一份历史），不用担心长期运行把日志撑爆
- 断开重连后若拿到新 IP（DHCP 重新分配），属正常，脚本会从 302 跳转动态获取新 IP
- WiFi 自动连接只在"HTTP 探测失败"（完全连不上外网）时才触发；已连着别的能用网络（如手机热点）时脚本判定在线，不会去抢连校园网
- `install_task.ps1` 已**去掉** `-RunOnlyIfNetworkAvailable`：否则完全断网时任务根本不会启动，"扫到就自动连"永远不会触发。**改动在重装任务后才生效**（管理员重跑 `run_install_admin.bat`）
- SYSTEM 身份下 `netsh wlan connect` 依赖"所有用户配置文件"（all-user profile）——手动连过一次后默认就是这种，一般可用；若日志里一直提示连不上而用户桌面下能连，可改用 `keepalive_loop.ps1` 在用户登录会话里跑 WiFi 连接
- 如果日志 1 分钟内没动静，先确认任务计划在跑：
  ```powershell
  Get-ScheduledTaskInfo -TaskName CampusAutoLogin
  ```

## 回滚

以管理员运行 `scripts\uninstall_task.ps1` 即可移除任务计划，脚本文件保留在目录中可手动删除。

## 关键信息

| 项目        | 值                                    |
| ----------- | ------------------------------------- |
| 校园网 SSID | HTU_Student                           |
| 认证方式    | Web Portal（深澜/Srun quickauth.do）  |
| 认证服务器  | http://10.101.2.194:6060              |
| 账号后缀    | 学生 `@htu`，教职工 `@htu.edu.cn` |
| 远程软件    | 网易 GameViewer（UU 远程）            |
| 无需验证码  | 是（模板 noTec）                      |
