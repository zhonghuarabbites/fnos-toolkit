# 飞牛 NAS 外网 HTTPS 访问 · 完整部署手册

> 记录时间：2026-10-21
> 环境：飞牛 fnOS（Debian 12），公网 IPv6，域名托管在 Cloudflare
> 目标：`https://nas.example.com:5667` 可从外网安全访问，IP 变化和证书到期全自动

---

## 0. 这套方案解决什么问题

家用 NAS 想在外网访问，常见三种做法：

| 方案 | 速度 | 安全 | 复杂度 | 结论 |
|---|---|---|---|---|
| Cloudflare Tunnel | 慢（流量绕境外节点） | 好 | 低 | ❌ 国内体验差 |
| 公网 IPv4 + 端口映射 | 快 | 中（需要公网 IP） | 中 | 视是否有公网 IPv4 |
| **公网 IPv6 + 直连 + 自有证书** | **最快（不过中间节点）** | **好（TLS 加密）** | 中 | ✅ 本方案 |

本方案要做四件事：

1. 让域名始终指向 NAS 当前 IPv6（IPv6 前缀会变）
2. 拿到浏览器信任的证书（自签证书会报「不安全」）
3. 让证书到期前自动续期
4. 续期后自动部署到飞牛的 nginx

四件事全部自动化后，你只需要记住一个 URL。

---

## 1. 最终架构

```
浏览器 ──https://nas.example.com:5667──▶ NAS(公网 IPv6 直连) ──▶ fnOS nginx :5667
                    │
                    ├─ DNS 层：Cloudflare 的 AAAA 记录
                    │   由 /usr/local/bin/cf-ddns6.sh 每 5 分钟对齐当前 IPv6
                    │
                    └─ 证书层：Let's Encrypt 通配符 *.example.com
                        certbot 自动续期 → deploy 钩子自动写入 nginx 并 reload
```

关键设计点：

- **只用 IPv6**：国内宽带 IPv6 普遍是公网可路由的，不需要端口映射（但要注意路由器 IPv6 防火墙）
- **通配符证书**：签一张 `*.example.com`，以后加 `photo.`、`pan.` 等子域名不用再签
- **DNS-01 验证**：不依赖 80 端口对外开放，靠 Cloudflare API 写临时 TXT 记录完成验证
- **分散职责**：DDNS 用脚本（可控），证书用 certbot（成熟），部署用钩子（自动）

---

## 2. 前置条件检查

在 NAS 上用 SSH 登录（root）后逐条确认。

### 2.1 有没有公网 IPv6

```bash
ip -6 addr show scope global | grep inet6
```

期望看到两类地址：

```
inet6 2409:xxxx:xxxx:xxxx::25c/128                ← 固定后缀地址，DNS 用这个
inet6 2409:xxxx:xxxx:xxxx:9b19:d900:51bd:9658/64  ← SLAAC 临时地址，会轮换，忽略
```

> **为什么要区分**：长的那条是隐私扩展自动生成的，可能每天变；`::xx` 这种短后缀是固定的，适合写进 DNS。
> 如果 NAS 上只有长地址，需要在 fnOS 网络设置里启用固定后缀，或改用完整长地址（但不稳定）。

### 2.2 外网能不能访问 5667

在**另一台不相关的电脑**上测（比如手机热点）：

```powershell
Test-NetConnection nas.example.com -Port 5667
```

`TcpTestSucceeded : True` 才算通。不通的话查两处：

- **路由器 IPv6 防火墙**：国内路由器默认拦截所有 IPv6 入站，需要给 NAS 放行 5667
- **fnOS 防火墙**：系统设置 → 安全性 → 防火墙

### 2.3 确认 nginx 的监听和端口

```bash
ss -ltnp | grep -E ':5666|:5667'
```

期望看到 `[::]:5666` 和 `[::]:5667`（IPv6 双栈监听）。

**飞牛的端口约定**：5666 = HTTP，5667 = HTTPS。

---

## 3. 第 1 步：创建 Cloudflare API Token

**这一步在干什么**：certbot 需要用 DNS-01 方式验证域名所有权——它会通过 Cloudflare API 临时写一条 TXT 记录，Let's Encrypt 查到后即证明域名归你。所以需要一枚只能改 DNS 的凭据。

### 操作

1. 登录 https://dash.cloudflare.com
2. 右上角头像 → **我的个人资料** → 左侧 **API 令牌**
3. **创建令牌** → 模板 **「编辑区域 DNS」** → 使用模板
4. 确认权限列表包含**两行**：

| 类型 | 资源 | 级别 |
|---|---|---|
| 区域 | DNS | 编辑 |
| 区域 | 区域 | **读取** ← 缺这行 certbot 会报 9109 |

5. 区域资源 → **特定区域** → `example.com`（不要选「所有区域」）
6. TTL、客户端 IP 筛选 → 留空
7. 继续 → 创建令牌 → **点页面上的复制按钮**（只显示一次）

### 马上验证（重要）

```bash
NEW='粘贴令牌'

echo "长度: ${#NEW}"     # 正常 45 位左右；多一两位通常是混进了换行/空格

curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer $NEW"; echo

curl -s "https://api.cloudflare.com/client/v4/zones?name=example.com" \
  -H "Authorization: Bearer $NEW" | head -c 300; echo
```

两条都必须 `"success":true`，第二条还要能看到 `"name":"example.com"`。

> ⚠️ **踩坑记录**：Token 必须带 `cfut_` 前缀，少了前缀会报 `1000 Invalid API Token`；复制时把 `g` 抄成 `q` 这种也会失败，症状完全一样。所以**每次都要 curl 验证后再往下走**。

> ⚠️ **不要用 Global API Key**：那是账号级全权限，飞牛自带的 DDNS 界面要的是它（邮箱 + Global Key），但一旦泄露等于 Cloudflare 账号被接管。

---

## 4. 第 2 步：安装 certbot

**这一步在干什么**：certbot 是 ACME 客户端，负责向 Let's Encrypt 申请证书、处理 DNS-01 验证、并定时检查续期。

```bash
apt update
apt install -y certbot python3-certbot-dns-cloudflare
```

`python3-certbot-dns-cloudflare` 是 DNS-01 插件，缺了 certbot 只能做 HTTP-01（需要 80 端口对外）。

> ⚠️ **踩坑记录**：不要走 `curl https://get.acme.sh | sh` 那条路——`get.acme.sh` 在部分网络环境会被 TLS 阻断（报 `Recv failure: Connection reset by peer`）。Debian 官方源的 certbot 更稳。

把令牌写进凭据文件：

```bash
mkdir -p /root/.secrets
printf 'dns_cloudflare_api_token = %s\n' "$NEW" > /root/.secrets/cloudflare.ini
chmod 600 /root/.secrets/cloudflare.ini
```

> `chmod 600` 是必须的，Certbot 会拒绝权限过宽的凭据文件。

---

## 5. 第 3 步：签发通配符证书

**这一步在干什么**：Let's Encrypt 验证通过后签发一张覆盖 `*.example.com` 和 `example.com` 的证书，存到 `/etc/letsencrypt/live/example.com/`。

```bash
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d '*.example.com' -d example.com \
  --agree-tos -m 你的邮箱@example.com --non-interactive \
  --server https://acme-v02.api.letsencrypt.org/directory
```

参数说明：

| 参数 | 作用 |
|---|---|
| `certonly` | 只申请证书，不自动改 web 服务器配置（我们自己控制） |
| `--dns-cloudflare` | 用 Cloudflare 插件做 DNS-01 验证 |
| `-d '*.example.com' -d example.com` | 通配符只覆盖子域名，裸域名要单独加 |
| `--non-interactive` | 全自动，不弹交互 |
| `--server .../directory` | 指定 Let's Encrypt 官方（不指定会走 ZeroSSL） |

成功输出：

```
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/example.com/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/example.com/privkey.pem
This certificate expires on 2027-01-19.
```

### 证书目录里各文件是什么

| 文件 | 内容 | 用途 |
|---|---|---|
| `cert.pem` | 只有叶子证书 | 一般不用 |
| `chain.pem` | 只有中间证书 | 面板要求单独填「中间证书」时 |
| `fullchain.pem` | 叶子 + 中间 + 根（4 张） | **部署用这个** |
| `privkey.pem` | 私钥 | 配对使用 |

> ⚠️ **踩坑记录**：只部署 `cert.pem` 会导致浏览器报「不安全」——缺中间证书，链不完整。必须用 `fullchain.pem`。

---

## 6. 第 4 步：让 AAAA 记录自动跟随 IPv6

**这一步在干什么**：运营商重拨后 IPv6 前缀会变（本次实测从 `c560` 变成 `cfe0`），域名要跟着变，否则外网访问中断。脚本每 5 分钟对齐一次。

### 6.1 创建脚本

```bash
tee /usr/local/bin/cf-ddns6.sh > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CF_TOKEN='在此填入你的 cfut_ 令牌'
ZONE_NAME='example.com'
NAME='nas.example.com'          # 要维护的子域名

# 取固定后缀的 IPv6（按需改 ::25c 这个后缀）
IP6=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | grep '::25c$' | head -1)
if [ -z "${IP6:-}" ]; then echo "$(date '+%F %T') 未取到可用 IPv6，跳过"; exit 0; fi

API_BASE='https://api.cloudflare.com/client/v4'
ZONE_ID=$(curl -s "$API_BASE/zones?name=$ZONE_NAME" \
  -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id // empty')
if [ -z "$ZONE_ID" ]; then echo "$(date '+%F %T') 取 Zone ID 失败（Token 权限？）"; exit 1; fi

API="$API_BASE/zones/$ZONE_ID/dns_records"
RESP=$(curl -s -H "Authorization: Bearer $CF_TOKEN" "$API?type=AAAA&name=$NAME")
REC_ID=$(echo "$RESP" | jq -r '.result[0].id // empty')
CUR=$(echo "$RESP"    | jq -r '.result[0].content // empty')

if [ "$CUR" = "$IP6" ]; then echo "$(date '+%F %T') 无变化 $IP6"; exit 0; fi

if [ -z "$REC_ID" ]; then
  curl -s -X POST "$API" -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
    --data "{\"type\":\"AAAA\",\"name\":\"$NAME\",\"content\":\"$IP6\",\"ttl\":120,\"proxied\":false}" >/dev/null
  echo "$(date '+%F %T') 已创建 AAAA -> $IP6"
else
  curl -s -X PATCH "$API/$REC_ID" -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
    --data "{\"content\":\"$IP6\",\"ttl\":120}" >/dev/null
  echo "$(date '+%F %T') 已更新 $CUR -> $IP6"
fi
SCRIPT

chmod 700 /usr/local/bin/cf-ddns6.sh
```

> **为什么要 `chmod 700`**：脚本里含明文令牌，只有 root 能读写执行。
> ⚠️ **踩坑记录**：如果误用了 `chmod 600`，脚本会变成「不可执行」，跑起来报 `Permission denied`。

### 6.2 装依赖并首次执行

```bash
apt install -y jq        # 脚本用 jq 解析 JSON
/usr/local/bin/cf-ddns6.sh
```

期望输出 `已创建 AAAA -> 2409:...::25c` 或 `无变化 ...`。

### 6.3 加入定时任务

```bash
( crontab -l 2>/dev/null | grep -v cf-ddns6 ; \
  echo '*/5 * * * * /usr/local/bin/cf-ddns6.sh >> /var/log/cf-ddns6.log 2>&1' ) | crontab -

crontab -l     # 确认已写入
```

### 6.4 去 Cloudflare 核对

DNS 记录里 `nasv6` 下应该只有**一条** AAAA，指向当前 IPv6，代理状态 = **仅 DNS**（灰云）。

> 必须是灰云：橙云代理只放行 80/443 等固定端口，5667 会被拦。

---

## 7. 第 5 步：把证书接入飞牛的 nginx

**这一步在干什么**：让飞牛 5667 端口不再用自签证书，改用我们签的 Let's Encrypt 通配符证书。

### 7.1 先搞清飞牛 nginx 怎么加载证书

```bash
cd / && /usr/trim/nginx/sbin/nginx -t                    # 语法检查（必须在 / 下运行）
grep -rn 'ssl_certificate' /usr/trim/nginx/conf/ | grep -v '#'
ls -la /usr/trim/nginx/conf/
systemctl list-units --type=service --state=running | grep -i nginx   # 服务名：trim_nginx
```

本次实际发现的关键事实：

```
nginx.conf:  ssl_certificate      $ssl_server_name;
nginx.conf:  ssl_certificate_key  $ssl_server_name;
```

含义：nginx 按访问的 **SNI（域名）** 动态加载证书，去 `/usr/trim/nginx/conf/` 下找**同名文件**（无扩展名），且该文件必须**同时包含证书链和私钥**。

另外还有一个 `ssl_certificate cert.pem` 的引用（该文件不存在），以及飞牛自己维护的 `conf/server.crt`（只有叶子证书）。

### 7.2 写入证书文件

```bash
LIVE=/etc/letsencrypt/live/example.com
CONF=/usr/trim/nginx/conf

# 备份原件
cp "$CONF/server.crt" "$CONF/server.crt.bak.$(date +%F)" 2>/dev/null
cp "$CONF/server.key" "$CONF/server.key.bak.$(date +%F)" 2>/dev/null

# 飞牛默认证书（备用路径）
cat "$LIVE/fullchain.pem" > "$CONF/server.crt"
cp  "$LIVE/privkey.pem"    "$CONF/server.key"
chmod 644 "$CONF/server.crt"; chmod 600 "$CONF/server.key"

# SNI 动态路径文件：证书链 + 私钥合并（真正生效的就是它）
cat "$LIVE/fullchain.pem" "$LIVE/privkey.pem" > "$CONF/nas.example.com"
chmod 600 "$CONF/nas.example.com"

systemctl reload trim_nginx
```

> 为什么两个都写：`$ssl_server_name` 是实际生效路径，但飞牛在 reload 时可能重建 `server.crt`，两边都保持正确最稳。

### 7.3 验证

```bash
# 下发的证书张数（应 ≥2，本次是 4）
echo | openssl s_client -showcerts -connect 127.0.0.1:5667 -servername nas.example.com 2>/dev/null | grep -c 'BEGIN CERTIFICATE'

# 链是否可信
echo | openssl s_client -connect 127.0.0.1:5667 -servername nas.example.com 2>&1 | grep 'Verify return code'

# SAN 是否覆盖子域名
echo | openssl s_client -connect 127.0.0.1:5667 -servername nas.example.com 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

期望：

```
4
Verify return code: 0 (ok)
X509v3 Subject Alternative Name: DNS:*.example.com, DNS:example.com
```

### 7.4 浏览器验收

打开 `https://nas.example.com:5667`，**先清一次站点 cookie 或用无痕窗口**。

> ⚠️ **踩坑记录**：证书换好、服务端一切正常，但 Chrome 仍显示「不安全」——原因是旧会话把之前的证书钉住了（certificate pinning / 缓存），清 cookie 后立刻正常。排查顺序永远是：**先看服务端证书 → 再怀疑浏览器缓存**。

---

## 8. 第 6 步：自动续期 + 自动部署

**这一步在干什么**：Let's Encrypt 证书只有 90 天。certbot 的 systemd timer 会自动续期，但续期后新证书需要被拷到 nginx 位置并让它重载——这靠 deploy 钩子完成。

### 8.1 创建钩子

```bash
tee /etc/letsencrypt/renewal-hooks/deploy/fnos-sync.sh > /dev/null <<'SCRIPT'
#!/bin/bash
set -e

LIVE="/etc/letsencrypt/live/example.com"
CONF="/usr/trim/nginx/conf"

# 1. nginx 默认路径（证书链 + 私钥分开）
cat "$LIVE/fullchain.pem" > "$CONF/server.crt"
cp  "$LIVE/privkey.pem"    "$CONF/server.key"
chmod 644 "$CONF/server.crt"
chmod 600 "$CONF/server.key"

# 2. SNI 动态路径（证书链与私钥合并的单文件）
cat "$LIVE/fullchain.pem" "$LIVE/privkey.pem" > "$CONF/nas.example.com"
chmod 600 "$CONF/nas.example.com"

# 3. 交给 systemd 重载（它自带 ExecStartPre 的 nginx -t 校验）
systemctl reload trim_nginx 2>/dev/null || systemctl restart trim_nginx

echo "$(date '+%F %T') fnos-sync: certificate deployed, trim_nginx reloaded"
SCRIPT

chmod +x /etc/letsencrypt/renewal-hooks/deploy/fnos-sync.sh
```

> 为什么钩子里不写 `nginx -t`：`trim_nginx.service` 的 `ExecStartPre` 已经包含 `/usr/trim/nginx/sbin/nginx -t`，且只有 systemd 启动时的**工作目录**才能让配置里的相对路径解析正确。
> ⚠️ **踩坑记录**：在 `/usr/trim/nginx/conf` 目录下手动跑 `nginx -t` 会报一堆 `open('assets/xxx.js') No such file or directory` —— 那是相对路径按当前目录解析导致的假错误，跟证书无关。

### 8.2 验证

```bash
# 演练续期（不动线上证书，也不触发过期的续期逻辑）
certbot renew --dry-run

# 直接跑钩子，确认它能正确部署 + reload
bash -x /etc/letsencrypt/renewal-hooks/deploy/fnos-sync.sh
```

> Debian 12 的 certbot 是 2.1.x，**没有** `--run-deploy-hooks` 参数，所以钩子要手动跑一次验证。

---

## 9. 第 7 步：完整验收清单

```bash
# 1) 服务在跑
systemctl is-active trim_nginx

# 2) 证书链完整（4 张）
echo | openssl s_client -showcerts -connect 127.0.0.1:5667 -servername nas.example.com 2>/dev/null | grep -c 'BEGIN CERTIFICATE'

# 3) 证书有效期
certbot certificates | grep -E 'Certificate Name|Expiry'

# 4) 续期演练
certbot renew --dry-run | tail -3

# 5) DDNS 脚本正常
/usr/local/bin/cf-ddns6.sh

# 6) 定时任务已装
crontab -l | grep cf-ddns6
systemctl list-timers | grep certbot
```

外网最终验证（在另一台设备上）：

```powershell
Test-NetConnection nas.example.com -Port 5667
# 浏览器打开 https://nas.example.com:5667，锁头正常
```

---

## 10. 日常运维

| 操作 | 命令 |
|---|---|
| 看证书剩余天数 | `certbot certificates` |
| 手动续期 | `certbot renew` |
| 手动部署证书 | `bash /etc/letsencrypt/renewal-hooks/deploy/fnos-sync.sh` |
| 看 DDNS 日志 | `tail -20 /var/log/cf-ddns6.log` |
| 看 nginx 日志 | `journalctl -u trim_nginx -n 50` |
| 重载 nginx | `systemctl reload trim_nginx` |
| 检查配置 | `cd / && /usr/trim/nginx/sbin/nginx -t` |

---

## 11. 加新子域名（如 photo.example.com）

1. **Cloudflare** 加一条 AAAA：名称 `photo`，内容 = NAS 当前 IPv6（`::25c` 那个），TTL 120，**仅 DNS**；
2. **证书不用动**——通配符 `*.example.com` 已覆盖；
3. 若新服务不在 5667，用 fnOS 的反向代理或另写 nginx server 块转发即可；
4. 需要 IP 自动跟随的话，把 `cf-ddns6.sh` 复制一份改 `NAME` 变量，或把它改成支持多个子域名。

---

## 12. 故障对照表（含本次全部踩坑记录）

| 现象 | 根因 | 处理 |
|---|---|---|
| `1000 Invalid API Token` | 令牌串少 `cfut_` 前缀 / 抄错字符 / 已被删除 | 重新建令牌，先 `curl verify` 再使用 |
| `9109 Invalid access token` | ① 令牌无效 ② 令牌缺「区域·区域·读取」权限 | 验证令牌；补齐 Zone Read 权限 |
| `6003 Invalid request headers` | 飞牛自带 DDNS 用旧式认证，不接受 Bearer Token | 别用飞牛 DDNS，改用 `cf-ddns6.sh` |
| 浏览器「不安全」但证书看着正常 | ① 缺中间证书（只发了 1 张）② 浏览器缓存/证书钉住 | 用 `fullchain.pem`；清 cookie / 无痕窗口 |
| 证书详情里 CN 对但 SAN 没有 `*.` | 部署的是裸域名证书 | 换成通配符证书 |
| `Permission denied` 跑脚本 | 误用 `chmod 600` 去掉了执行位 | `chmod 700` |
| `nginx -t` 报一堆 `open('assets/...')` | 在 `conf/` 目录下执行，相对路径解析错 | `cd / && /usr/trim/nginx/sbin/nginx -t` |
| `getcwd: cannot access parent directories` | 当前目录被服务 reload 时重建 | 无害；建议在 `/` 或 `/root` 下执行 |
| 域名打不开但 IPv6 直连正常 | AAAA 记录过期（运营商换了前缀） | 跑 `cf-ddns6.sh`；检查 cron 和日志 |
| `ERR_CONNECTION_REFUSED` 但 TCP 通 | 端口不对（用了 5666 HTTP 或 80） | HTTPS 用 5667，URL 必须带 `https://` |
| certbot 续期成功但网站证书没换 | deploy 钩子没执行或执行失败 | 手动跑钩子；检查脚本权限和路径 |

---

## 13. 安全基线（必做）

- [ ] **关闭 5666 明文端口的外网访问**：防火墙限制为仅内网，或只保留 5667
- [ ] **开启飞牛二次验证**：安全性 → 账号安全（这台机器已公网可达）
- [ ] **Cloudflare 令牌最小权限**：仅 DNS 编辑 + 区域读取，区域限定单域名；定期轮换
- [ ] **私钥不外流**：不要长期放在 SMB 共享目录；用完即删
- [ ] **删除不用的凭据**：旧令牌、飞牛自带的 DDNS 条目、无用的自签证书
- [ ] **关注登录日志**：外网暴露的登录页会被扫，开启失败锁定

---

## 14. 彻底重装（换机器/重装系统时）

把下面变量填好，按 3→4→5→6→7→8 节顺序执行即可。核心变量：

```bash
DOMAIN='example.com'              # 主域名
SUB='nasv6'                      # 子域名前缀
EMAIL='你的邮箱@example.com'
CF_TOKEN='cfut_xxxxxxxxxxxx'
IPV6_SUFFIX='::25c'              # NAS 固定后缀地址的后缀
```

替换检查点：

1. `cf-ddns6.sh` 里的 `CF_TOKEN`、`ZONE_NAME`、`NAME`
2. `/root/.secrets/cloudflare.ini` 里的令牌
3. `fnos-sync.sh` 里的 `LIVE`（证书目录名 = 主域名）和 `CONF`（nginx 配置目录）
4. nginx 的 SNI 文件名 = `$SUB.$DOMAIN`（**必须与访问域名完全一致**）

---

## 附：本次环境实测数据（便于对照）

```
NAS IPv6（固定）  : 2409:xxxx:xxxx:xxxx::25c
Cloudflare Zone   : example.com  (ID 79894b51ecfc0d67a28d587cd7d4b422)
证书              : Let's Encrypt, CN=*.example.com, issuer YE1
有效期            : 2026-10-21 ~ 2027-01-19
下发证书链        : 4 张
nginx 服务名      : trim_nginx
nginx 配置目录    : /usr/trim/nginx/conf
nginx 二进制      : /usr/trim/nginx/sbin/nginx
访问端口          : 5667 (HTTPS) / 5666 (HTTP，建议只留内网)
```
