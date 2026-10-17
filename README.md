# 河南师范大学校园网自动连接方案

[10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10&amp;wlanacname=HSD-BRAS-2&amp;mac=aa:bb:cc:dd:ee:ff&amp;vlan=19953605&amp;hostname=desktop-example&amp;rand=1e45325ef8fad5e&amp;url=http%3A%2F%2F1.1.1.1](http://10.101.2.194:6060/portal.do?wlanuserip=10.104.0.10&wlanacname=HSD-BRAS-2&mac=aa:bb:cc:dd:ee:ff&vlan=19953605&hostname=desktop-example&rand=1e45325ef8fad5e&url=http%3A%2F%2F1.1.1.1)

## 项目目标

办公室工位电脑（某品牌笔记本，Windows 11）连接 HTU_Student 校园网，在以下场景下自动恢复网络和远程控制（GameViewer），无需到现场：

- 电脑重启 / 断电恢复
- 校园网认证过期 / 被踢下线
- 突然断网后恢复

## 方案概览

采用**电脑端保底方案（方案A）**，不刷路由器、不改 BIOS：

1. **GameViewer 远程服务**已配置为 LocalSystem 自动启动（现状），Windows 账号无密码开机自动登录，保证网络通了就能被远程连上。
2. **自动认证脚本** `scripts/auto_login.ps1`：
   - 每 1 分钟 ping 223.5.5.5 检测外网
   - 不通时自动捕获 Portal 跳转，向 `http://10.101.2.194:6060/quickauth.do` 提交账号密码
   - 失败重试、写日志、绕开系统代理
3. **Windows 任务计划** `CampusAutoLogin`（当前启用方案）：
   - 主体 SYSTEM，开机后 30 秒启动，每 1 分钟执行一次
   - 不依赖用户登录
   - 安装：管理员运行 `install_task.ps1`

> 备用方案：`scripts/keepalive_loop.ps1` + 启动文件夹快捷方式（免管理员）。
> 曾在任务计划无法安装时使用，任务计划安装成功后已停用，脚本保留备用。

## 目录结构

```
20261017-自动连接校园网/
├── README.md                    # 本文件
├── .gitignore
├── scripts/
│   ├── config.ini               # 配置（账号密码，密码需手动填写）
│   ├── auto_login.ps1           # 主认证脚本
│   ├── install_task.ps1          # 安装任务计划（需管理员）
│   ├── uninstall_task.ps1        # 卸载任务计划（回滚）
│   ├── keepalive_loop.ps1        # 备用：启动文件夹守护循环（免管理员，已停用）
│   ├── run_install_admin.bat     # 一键管理员安装入口
│   └── tests/
│       └── test_captive_detection.ps1   # 探测逻辑回归测试
├── docs/
│   ├── 01-现状报告.md
│   ├── 02-方案设计.md
│   ├── 03-操作记录.md
│   ├── 04-回滚步骤.md
│   └── 05-原理说明.md            # 系统原理与认证流程详解
└── logs/
    └── auto_login.log           # 运行日志（git 忽略）
```

## 快速开始

### 1. 填写校园网密码

编辑 `scripts/config.ini`，把 `Password = YOUR_PASSWORD_HERE` 改成你的真实校园网密码。

### 2. 安装任务计划（需要管理员）

右键「以管理员身份运行」 PowerShell，执行：

```powershell
cd E:\06DateClass\20261017-自动连接校园网\scripts
.\install_task.ps1
```

### 3. 查看日志

```powershell
Get-Content E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log -Tail 20 -Wait
```

### 4. 可调配置（改 `scripts\config.ini`，改完下一分钟自动生效，无需重装）

| 配置项 | 默认 | 说明 |
|---|---|---|
| `ProbeIntervalMinutes` | `1` | 探测间隔（分钟）。`1`=每分钟，`5`=每5分钟，`0`=任务每次触发都探测 |
| `LogMode` | `normal` | `normal`=每次探测写一条日志；`heartbeat`=在线时按心跳间隔写（防刷屏） |
| `HeartbeatMinutes` | `30` | 仅 heartbeat 模式生效：在线时多少分钟写一条心跳 |
| `RetryInterval` / `MaxRetries` | `5` / `3` | 单次认证失败后的重试间隔（秒）与最多重试次数 |

> 说明：任务计划本身保持每 1 分钟触发一次，脚本读 `ProbeIntervalMinutes` 自行节流——未到间隔的运行会静默跳过，不占资源。
## 测试验收（怎么测）

> ⚠️ **最重要前提：测试时电脑必须连的是校园网 `HTU_Student`，绝不能是手机热点！**
> 手机热点（如 Redmi K70 Ultra）网络里，校园网认证服务器 `10.101.2.194` 根本不可达，脚本无法认证。
> 确认方法：运行 `netsh wlan show interfaces`，看 `SSID` 那行是不是 `HTU_Student`。
> 若电脑断开校园网后自动连了手机热点，手动切回：
>
> ```powershell
> netsh wlan connect name="HTU_Student" ssid="HTU_Student"
> ```

### 场景 1：断网自动重认证（最常用）

1. 确认当前连的是 `HTU_Student`（见上方前提）
2. 打开日志实时窗口：
   ```powershell
   Get-Content E:\06DateClass\20261017-自动连接校园网\logs\auto_login.log -Tail 30 -Wait
   ```
3. 点右下角 WiFi → **断开 `HTU_Student`**
4. 等 10 秒，**重新连接 `HTU_Student`**（连的时候看清 SSID，别连成手机热点）
5. 观察日志，**1 分钟内**应依次出现：
   ```
   [INFO] 检测到未认证（HTTP 被劫持到认证页），开始自动认证...
   [INFO] 捕获到 Portal 跳转: http://10.101.2.194:6060/portal.do?...
   [INFO] 第 1/3 次提交 quickauth.do ...
   [INFO] 认证成功！message=...
   ```
6. 验证：能打开网页 + 用另一台设备通过 GameViewer 能连上这台电脑

### 场景 2：重启电脑

1. 重启电脑
2. 开机后自动进桌面（账号无密码），任务计划在开机 30 秒后启动，每 1 分钟检测
3. 等 1~2 分钟，用另一台设备通过 GameViewer 连接
4. 判断标准：远端能连上 = 通过；连不上就查日志

### 场景 3：认证过期（可选）

1. 浏览器打开认证页 `http://10.101.2.194:6060/portal.do`，找到"注销/下线"按钮点掉
2. 或等校园网自然踢下线
3. 观察日志是否 1 分钟内自动重新认证

### 判断标准（三个都满足 = 通过）

- 日志出现 `认证成功！`
- 浏览器能正常打开网页
- 远端设备 GameViewer 能连上电脑

- 校园网未认证时有**两种劫持方式**：301 跳转到认证页，或直接返回 200+认证页 HTML（深澜透明劫持）。脚本对两种都识别——只要探测响应里出现 portal.do/quickauth/wlanuserip 特征，就判定未认证并自动提交。你可以先跑回归测试确认探测逻辑正常：
  ```powershell
  powershell -ExecutionPolicy Bypass -File E:\06DateClass\20261017-自动连接校园网\scripts\tests\test_captive_detection.ps1
  ```
  预期输出：`7 通过, 0 失败`
### 注意事项

- 日志在线时 30 分钟才写一条心跳（防刷屏），**只有断网瞬间才写详细日志**，所以盯日志要在"断开 WiFi 后立刻"看
- 断开重连后若拿到新 IP（DHCP 重新分配），属正常，脚本会从 302 跳转动态获取新 IP
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
