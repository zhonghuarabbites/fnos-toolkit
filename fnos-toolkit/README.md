# fnos-toolkit

飞牛 fnOS / 群晖 DSM 的运维脚本集合：**外网 HTTPS 直连访问** 与 **网络中断告警**。

全部为纯 shell / 单文件 Worker 实现，零依赖（只用 `curl`、`openssl`、`bash`），不依赖任何付费服务。

> English: Self-hosted NAS operations toolkit — direct IPv6 + HTTPS access with auto-renewing certificates, and network outage alerting (local watchdog + Cloudflare Worker heartbeat). All scripts are dependency-light and free to run.

---

## 目录结构

```
.
├── scripts/                          # 可执行脚本
│   ├── cf-ddns6.sh                   # Cloudflare IPv6 DDNS（AAAA 自动跟随前缀变化）
│   ├── alidns-ddns6.sh               # 阿里云云解析 IPv6 DDNS（RPC + HMAC-SHA1，无需 jq）
│   ├── fnos-sync.sh                  # certbot 续期部署钩子（飞牛 nginx SNI 证书）
│   ├── fnos-sync-aliyun.sh           # 同上，配合 acme.sh 使用
│   ├── netwatch.sh                   # 网络看门狗（探测 + 告警 + 心跳）
│   └── heartbeat-worker.js           # Cloudflare Worker：外部心跳 + 通知出口
├── examples/                         # 配置文件模板
│   ├── netwatch.conf.example
│   ├── synology-cf-ddns6.sh          # 群晖版 DDNS（不依赖 jq）
│   └── synology-acme-dsm-deploy.sh   # 群晖：acme.sh 签发 + DSM API 自动部署
└── docs/
    ├── fnos-https-access.zh-CN.md      # 飞牛：外网 HTTPS 访问完整部署
    ├── network-watchdog.zh-CN.md       # 网络告警完整部署
    ├── wechat-mp-push.zh-CN.md         # 微信公众号推送细节
    ├── synology-https-access.zh-CN.md  # 群晖：外网 HTTPS 访问
    └── aliyun-dns-migration.zh-CN.md   # 从 Cloudflare 迁到阿里云云解析
```

---

## 两个能力

### 一、外网 HTTPS 直连访问

不用 Cloudflare Tunnel（中转慢）、不做端口映射，直接走**公网 IPv6 + Let's Encrypt 通配符证书**。

```
浏览器 ──https://nas.example.com:5667──▶ NAS(IPv6 直连) ──▶ nginx
            ├ DNS  ：Cloudflare AAAA，由 cf-ddns6.sh 每 5 分钟对齐当前 IPv6
            └ 证书 ：*.example.com 通配符，certbot 自动续期 + 钩子自动部署
```

解决的核心问题：

| 问题 | 脚本的解法 |
|---|---|
| 运营商 IPv6 前缀会变，域名失效 | `cf-ddns6.sh` 定时比对并更新 AAAA |
| 自签证书浏览器报「不安全」 | Let's Encrypt 通配符证书，一次覆盖所有子域名 |
| 证书 90 天过期 | certbot timer + deploy hook 自动续期并同步到 nginx |
| 飞牛 nginx 用 `$ssl_server_name` 动态加载证书 | 钩子同时写 `server.crt` 与 SNI 命名的合并文件 |

### 二、网络中断告警（微信 + 邮件）

**NAS 断网时它自己发不出消息**，所以需要两层：

```
┌── NAS（每分钟）──┐            ┌── Cloudflare（每 5 分钟）──┐
│ netwatch.sh      │  /ping     │ Worker + KV                │
│ ├ 探测 4 层      │ ─────────▶ │ ├ 记录心跳时间             │
│ ├ 本地邮件告警   │            │ ├ 超时 → 微信 + 邮件       │
│ └ POST /notify ──┼──────────▶ │ └ /notify → 微信           │
└──────────────────┘            └────────────────────────────┘
```

| 场景 | 通知路径 | 微信 | 邮件 |
|---|---|---|---|
| IPv6 丢失 / DNS 故障（NAS 有网） | NAS 本地邮件 + Worker 微信 | ✅ | ✅ |
| 短暂断网后恢复 | 同上，附中断时长 | ✅ | ✅ |
| **NAS 断网 / 关机 / 断电** | Worker 心跳超时 | ✅ | ✅（Resend） |
| NAS 重新上线 | Worker 检测恢复 | ✅ | ✅ |

设计要点：

- **微信 access_token 只有一个持有者**（Worker）。NAS 若也直连微信 API 会互相踢下线，触发 `40001 invalid credential`；
- **NAS 自己发邮件，Worker 的 `/notify` 只发微信**，避免同一事件收到两封重复邮件；
- 两条链路相互独立：Cloudflare 不可达时本地邮件仍发得出去。

---

## 快速开始

完整步骤见对应文档，这里只给最短路径。

### 1. 外网 HTTPS 访问（飞牛）

```bash
# ① 签发通配符证书（DNS-01，不需要开放 80 端口）
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d '*.example.com' -d example.com \
  --agree-tos -m you@example.com --non-interactive \
  --server https://acme-v02.api.letsencrypt.org/directory

# ② 装部署钩子（续期后自动同步到 nginx）
install -m 700 scripts/fnos-sync.sh /etc/letsencrypt/renewal-hooks/deploy/fnos-sync.sh

# ③ 装 DDNS（AAAA 自动跟随 IPv6 前缀）
install -m 700 scripts/cf-ddns6.sh /usr/local/bin/cf-ddns6.sh
#   编辑后填入自己的令牌与域名，然后：
( crontab -l 2>/dev/null; echo '*/5 * * * * /usr/local/bin/cf-ddns6.sh >> /var/log/cf-ddns6.log 2>&1' ) | crontab -
```

详见 [`docs/fnos-https-access.zh-CN.md`](docs/fnos-https-access.zh-CN.md)。

### 2. 网络告警

```bash
# ① 部署 Worker（Cloudflare 网页粘贴 scripts/heartbeat-worker.js）
#    绑定 KV 名 HEARTBEAT_KV，变量见文档

# ② 部署本地看门狗
install -m 700 scripts/netwatch.sh /usr/local/bin/netwatch.sh
install -m 600 examples/netwatch.conf.example /etc/netwatch.conf
#   编辑 /etc/netwatch.conf 填入 HEARTBEAT_URL / NOTIFY_URL / MAIL_*

/usr/local/bin/netwatch.sh test     # 通道自测

( crontab -l 2>/dev/null; echo '* * * * * /usr/local/bin/netwatch.sh >> /var/log/netwatch-cron.log 2>&1' ) | crontab -
```

详见 [`docs/network-watchdog.zh-CN.md`](docs/network-watchdog.zh-CN.md)。

---

## 前置条件

| 项 | 要求 |
|---|---|
| 系统 | 飞牛 fnOS（Debian 12）或任意 Debian/Ubuntu；群晖需按群晖文档调整路径 |
| 网络 | 家宽具备**公网 IPv6**（国内三大运营商基本都有） |
| 域名 | 托管在 Cloudflare（DDNS 与证书验证都走它的 API） |
| 依赖 | `bash` `curl` `openssl` `ping`；DDNS 脚本需 `jq`（阿里云版不需要）；邮件需 `msmtp` |

> 没有公网 IPv6 也能用「网络告警」部分——它只要求 NAS 能出网。

---

## 安全说明

⚠️ **仓库里的所有脚本都不包含任何密钥**，使用前必须自己填写：

```bash
# 需要自己配置的三处
/root/.secrets/cloudflare.ini        # Cloudflare API Token（Zone:DNS:Edit + Zone:Zone:Read）
/usr/local/bin/cf-ddns6.sh           # 脚本顶部 CF_TOKEN
/etc/netwatch.conf                   # HEARTBEAT_URL / NOTIFY_URL / MAIL_*
```

最佳实践：

- Cloudflare 令牌用**最小权限**（只给 DNS 编辑 + 区域读取，区域限定单个域名）；
- 含密钥的文件一律 `chmod 600`，可执行脚本 `chmod 700`；
- 敏感凭据**不要提交到 Git**（`.gitignore` 已排除常见模式）；
- 定期轮换令牌，顺序：建新的 → 验证 → 改配置 → 测通 → 删旧的。

---

## 已知限制

- Cloudflare `*.workers.dev` 域名在中国大陆常被阻断，请给 Worker 配**自定义域名**；
- Cloudflare 的 Cron 使用 **UTC**（`*/5` 这类间隔表达式与时区无关）；
- 微信 `access_token` 全局唯一，同一 appID 只能有一个高频刷新方，因此本方案让 Worker 独占；
- 微信公众号**订阅号无主动推送权限**，个人使用建议申请「接口测试号」；
- 本工具假定 NAS 上有 root 权限；请自行评估公网暴露风险，建议配合二次验证与登录失败锁定。

---

## 许可

MIT，见 [LICENSE](LICENSE)。

## 贡献

Issue / PR 都欢迎。提交前请确认：**代码里没有任何真实域名、IP、令牌或邮箱**。
