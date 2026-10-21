# 飞牛 NAS · 网络告警部署说明 v3（微信 + 邮件）

> 最后更新：2026-10-21（架构收敛版，v1 企业微信 / v2 PushPlus 与公众号直推均已废弃）
> 设备：飞牛 fnOS，公网 IPv6，域名在 Cloudflare

---

## 0. 架构：三层职责，各管一段

```
┌────── NAS（每分钟 cron）──────┐        ┌────── Cloudflare（每 5 分钟）──────┐
│ netwatch.sh                   │        │ Worker + KV                        │
│  ├ 探测：网关/IPv4/IPv6/DNS   │ /ping  │  ├ 记录最后心跳时间                │
│  ├ 状态机（连续 3 次才判定）  │ ─────▶ │  ├ cron 检查：超时 → 微信+邮件     │
│  ├ 邮件：本地 msmtp 直发      │        │  └ /notify：接收 NAS 告警 → 发微信 │
│  └ 微信：POST /notify ────────┼──────▶ │                                    │
└───────────────────────────────┘        └────────────────────────────────────┘
```

### 三条设计原则

| 原则 | 解决的坑 |
|---|---|
| **微信 access_token 只有一个持有者（Worker）** | 之前 NAS 与 Worker 各自刷 token，互相踢下线 → `40001 invalid credential` |
| **NAS 自己发邮件，Worker 的 /notify 只发微信** | 避免同一事件收到两封重复邮件 |
| **常驻两条独立链路** | Cloudflare 挂了还有本地邮件；NAS 挂了还有外部心跳 |

### 每种场景走哪条路

| 场景 | 发现者 | 通知路径 | 微信 | 邮件 |
|---|---|---|---|---|
| IPv6 丢失 / DNS 故障 | NAS | 本地邮件 + Worker 微信 | ✅ | ✅ 本地 SMTP |
| 短暂断网后恢复 | NAS | 本地邮件 + Worker 微信（含中断时长） | ✅ | ✅ 本地 SMTP |
| **NAS 断网 / 关机 / 断电** | Worker | Worker 微信 + Resend 邮件 | ✅ | ✅ Resend |
| NAS 重新上线 | Worker | Worker 微信 + Resend 邮件（含中断时长） | ✅ | ✅ Resend |

> Cloudflare 不可达时（罕见）：NAS 侧邮件仍能发出去，只是没有微信。

---

## 1. 文件清单

| 文件 | 部署位置 | 权限 |
|---|---|---|
| `netwatch.sh` | `/usr/local/bin/netwatch.sh` | 700 |
| `netwatch.conf.example` | `/etc/netwatch.conf` | 600 |
| `heartbeat-worker.js` | Cloudflare Worker（网页粘贴） | — |
| `/root/.msmtprc` | NAS（手写） | 600 |

**已废弃、需要删除的**（v1/v2 遗留）：

```bash
rm -f /usr/local/bin/wx-push.sh /etc/wxpush.conf
```

`/etc/netwatch.conf` 里的 `WECOM_WEBHOOK`、`PUSHPLUS_TOKEN`、`WX_PUSH_CMD` 三行也一并删掉。

---

## 2. 第 1 步：邮件通道（本地 msmtp）

QQ 邮箱 → 设置 → 账号 → 开启 **SMTP** → 生成**授权码**（16 位）。

```bash
apt update && apt install -y msmtp msmtp-mta

cat > /root/.msmtprc <<'EOF'
defaults
auth           on
tls            on
tls_starttls   off
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /root/msmtp.log

account        qq
host           smtp.qq.com
port           465
from           you@example.com
user           you@example.com
password       16位授权码

account default : qq
EOF

chmod 600 /root/.msmtprc
```

验证：

```bash
printf 'Subject: SMTP 测试\n\n收到说明邮件通道已通。\n' | msmtp -a qq you@example.com
echo "退出码: $?"
```

期望 `退出码: 0` 且邮箱收到信。

> `logfile` 写 `/root/msmtp.log`，不要用 `/var/log/msmtp.log`（飞牛上会 Permission denied 一直刷警告）。

---

## 3. 第 2 步：Cloudflare Worker

### 3.1 建 KV

Cloudflare → 存储和数据库 → **Workers KV** → 创建命名空间 `netwatch-kv`。

### 3.2 建 Worker

Workers & Pages → 创建应用程序 → **Workers** → Hello World → 名 `netwatch-heartbeat` → 部署
→ 编辑代码 → 全选替换为 `heartbeat-worker.js` → 部署

> ⚠️ 「使用 Cloudflare Access 保护」必须**关闭**，否则 NAS 心跳被拦到登录页。

### 3.3 绑定与变量

**绑定**（Settings → 绑定 → KV 命名空间）：

| 变量名 | 命名空间 |
|---|---|
| `HEARTBEAT_KV` | `netwatch-kv` |

**环境变量**（可一次多行粘贴）：

```
SECRET=CHANGE_ME_RANDOM_SECRET
NODE_NAME=fnos
ALERT_AFTER_SEC=600
WX_APPID=测试号appID
WX_SECRET=测试号appsecret
WX_OPENID=o开头的openid
WX_TEMPLATE_ID=模板ID
```

敏感项勾「密钥」。**改完必须点部署**。

### 3.4 微信模板（测试号）

`https://mp.weixin.qq.com/debug/cgi-bin/sandbox?t=sandbox/login` → 扫码 → 关注二维码 → 抄 openid
→ 「模板消息接口 → 新增测试模板」，内容必须四段：

```
告警类型：{{first.DATA}}
详细内容：{{keyword1.DATA}}
发生时间：{{keyword2.DATA}}
备注：{{remark.DATA}}
```

> 页面上的「接口配置信息（URL + Token）」不用填。

### 3.5 Cron

设置 → 触发器 → Cron 触发器 → 添加 → **Cron 表达式**标签 → `*/5 * * * *`

> Cloudflare 的 cron 用 UTC；`*/5` 与时区无关。只有写「每天几点」才需换算。

### 3.6 自定义域名

`*.workers.dev` 在国内基本不可达，必须配自己的域名：
设置 → **域和路由 → 添加 → 自定义域** → `hb.example.com` → 等 Active。

### 3.7 验证

```bash
curl -s https://hb.example.com/                                   # netwatch worker v3
curl -s "https://hb.example.com/ping?k=CHANGE_ME_RANDOM_SECRET"             # ok
curl -s "https://hb.example.com/test?k=CHANGE_ME_RANDOM_SECRET"             # sent:wechat
```

`/test` 会立刻发一条到微信，**这是最快的通道验证方式**。

---

## 4. 第 3 步（可选）：Resend 邮件

只有当你想「NAS 断网期间也收到邮件」时才需要。常态告警的邮件由 NAS 本地 SMTP 发送，与 Resend 无关。

1. https://resend.com 注册（免费 100 封/天）
2. Domains → Add Domain → `example.com`
3. 按提示在 Cloudflare 加 3 条 DNS（灰云）：

| 类型 | 名称 | 值 |
|---|---|---|
| MX | `send` | `feedback-smtp.us-east-1.amazonses.com`（优先级 10） |
| TXT | `send` | `v=spf1 include:amazonses.com ~all` |
| TXT | `resend._domainkey` | `p=MIGf...` |

4. Verify 通过后 → API Keys → Create（Sending access）→ 复制 `re_` key

Worker 加三个变量并部署：

```
RESEND_API_KEY=re_xxxx        （勾密钥）
MAIL_FROM=notify@example.com
MAIL_TO=you@example.com
```

验证：`/test` 应返回 `sent:wechat,mail`。

---

## 5. 第 4 步：NAS 部署 netwatch

### 5.1 传文件

```powershell
# 自己电脑 PowerShell
scp "docs/netwatch.sh" admin@192.168.1.10:/home/admin/
scp "docs/netwatch.conf.example" admin@192.168.1.10:/home/admin/
```

### 5.2 安装

```bash
# NAS root
cp /home/admin/netwatch.sh /usr/local/bin/netwatch.sh
chmod 700 /usr/local/bin/netwatch.sh
bash -n /usr/local/bin/netwatch.sh && echo "语法 OK"

cp /home/admin/netwatch.conf.example /etc/netwatch.conf
chmod 600 /etc/netwatch.conf
```

### 5.3 改配置（只留这 8 项）

```bash
NODE_NAME="fnos"
HEARTBEAT_URL="https://hb.example.com/ping?k=CHANGE_ME_RANDOM_SECRET"
NOTIFY_URL="https://hb.example.com/notify?k=CHANGE_ME_RANDOM_SECRET"
MAIL_TO="you@example.com"
MAIL_FROM="you@example.com"
MAIL_ACCOUNT="qq"
FAIL_THRESHOLD=3
DEGRADED_RENOTIFY=3600
```

> 如果沿用旧配置文件，**删掉** `WECOM_WEBHOOK` / `PUSHPLUS_TOKEN` / `WX_PUSH_CMD` 三行（新版脚本已不读它们，留着只会混淆）。

### 5.4 测试

```bash
/usr/local/bin/netwatch.sh test
```

期望：`✅ 已发出（本地邮件 / Worker 微信，至少一条成功）`，邮箱和微信都收到。

### 5.5 手动跑一次 + 装 cron

```bash
/usr/local/bin/netwatch.sh
ls -l /var/lib/netwatch/         # 应有 fail_count，值为 0

( crontab -l 2>/dev/null | grep -v netwatch ; \
  echo '* * * * * /usr/local/bin/netwatch.sh >> /var/log/netwatch-cron.log 2>&1' ) | crontab -
crontab -l | grep netwatch
```

> 临时停：`crontab -l | grep -v netwatch | crontab -`
> 恢复：`( crontab -l ; echo '* * * * * /usr/local/bin/netwatch.sh >> /var/log/netwatch-cron.log 2>&1' ) | crontab -`
> 别用 `sed` 加 `#` 注释那行，不可靠。

---

## 6. 验收

### 6.1 三个通道各测一次

```bash
# 本地邮件 + Worker 微信（NAS 侧总入口）
/usr/local/bin/netwatch.sh test

# Worker 侧全通道
curl -s "https://hb.example.com/test?k=CHANGE_ME_RANDOM_SECRET"

# Worker 的 /notify（只发微信，模拟 NAS 告警）
curl -s -X POST "https://hb.example.com/notify?k=CHANGE_ME_RANDOM_SECRET" \
  -H 'Content-Type: application/json' -d '{"title":"接口测试","body":"来自 /notify 的测试"}'
```

### 6.2 端到端实测（必做）

```bash
# 停掉本地心跳，制造「NAS 离线」假象
crontab -l | grep -v netwatch | crontab -
curl -s "https://hb.example.com/ping?k=CHANGE_ME_RANDOM_SECRET"; echo
```

等 **10–15 分钟** → 应收到微信（+ 邮件，若配了 Resend）：

```
【fnos】疑似断网
已 11 分钟没有收到心跳。可能原因：宽带断开、光猫或路由器断电、NAS 关机、IPv6 前缀变化。
```

恢复：

```bash
( crontab -l ; echo '* * * * * /usr/local/bin/netwatch.sh >> /var/log/netwatch-cron.log 2>&1' ) | crontab -
/usr/local/bin/netwatch.sh
```

1 分钟内收到「已恢复 + 中断时长」。

### 6.3 降级告警实测（可选）

把 `TARGET_V6` 临时改成 `100::1`，跑一次 `netwatch.sh`，应收到「网络降级：IPv6 不可用」。测完改回。

---

## 7. 日常维护

| 需求 | 命令 |
|---|---|
| 看状态变化 | `tail -20 /var/log/netwatch.log` |
| 看 cron 报错 | `tail -20 /var/log/netwatch-cron.log` |
| 看邮件日志 | `tail -20 /root/msmtp.log` |
| 手动探测一次 | `/usr/local/bin/netwatch.sh` |
| 测本地通道 | `/usr/local/bin/netwatch.sh test` |
| 测 Worker 通道 | `curl -s "https://hb.example.com/test?k=你的SECRET"` |
| 看 Worker 日志 | Cloudflare → Worker → Observability |
| 改 Worker 变量 | 改完**必须点部署** |

---

## 8. 故障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `netwatch.sh test` 全失败 | 配置没填 / msmtp 没配 / NOTIFY_URL 错 | `bash -x /usr/local/bin/netwatch.sh test` |
| 微信收不到，邮件正常 | Worker 侧问题 | `curl .../test?k=...` 看返回 |
| `sent:wechat` 但微信没消息 | 测试号没关注 / 服务通知免打扰 | 重新扫码；检查微信通知设置 |
| `wechat:errcode-40001` | token 冲突（说明还有别处在刷） | 确认只有 Worker 调微信 API，删掉 `wx-push.sh` |
| `wechat:errcode-40013/40125` | appID / appsecret 错 | 核对测试号页面 |
| `wechat:errcode-47003` | 模板字段不匹配 | 模板必须是 `first/keyword1/keyword2/remark` |
| `mail:http-403` | Resend 域名未验证 / from 不在该域 | 重新 Verify；`MAIL_FROM` 用 `@example.com` |
| `/ping` 返回 `forbidden` | SECRET 与 `k=` 不一致 | 核对，注意值别带引号空格 |
| `workers.dev` 打不开 | 国内阻断 | 用 `hb.example.com` |
| 断网但没告警 | ① 变量没配 ② cron 没删（心跳还在续） ③ 时间没等够 | 依次排查 |
| 脚本 `$'\r': command not found` | Windows 换行 | `sed -i 's/\r$//' 文件` |
| 脚本 `Permission denied` | 缺执行位 | `chmod 700 文件` |

---

## 9. 参数与费用

| 参数 | 建议 | 说明 |
|---|---|---|
| NAS cron | 每分钟 | 一天 1440 次，开销可忽略 |
| `FAIL_THRESHOLD` | 3 | 约 3 分钟判定，过滤抖动 |
| Worker cron | `*/5 * * * *` | 5 分钟粒度，10–15 分钟内告警 |
| `ALERT_AFTER_SEC` | 600 | 太短会被夜间重拨吵醒 |
| `DEGRADED_RENOTIFY` | 3600 | IPv6 长期异常每小时提醒一次 |

| 项目 | 费用 |
|---|---|
| QQ 邮箱 SMTP（本地邮件） | 0 元 |
| 公众号测试号（微信） | 0 元 |
| Cloudflare Worker + KV + Cron | 0 元（免费额度 10 万请求/天） |
| Resend（可选） | 0 元（100 封/天） |
