# 群晖 Synology DSM · 外网 HTTPS 访问完整部署手册

> 编写时间：2026-10-21
> 适用：DSM 7.x（DSM 6 的差异在文中标注）
> 场景：公网 IPv6，域名托管在 Cloudflare，希望通过 `https://nasv6.example.cn:5001` 安全访问
> 目标：IP 变化自动跟随、证书自动续期、续期后自动部署，全程无需人工干预

---

## 0. 与飞牛方案的核心差异（先读这一段）

群晖有几处和飞牛根本不同，照搬飞牛手册会踩坑：

| 项目 | 飞牛 fnOS | 群晖 DSM |
|---|---|---|
| 默认 HTTPS 端口 | 5667 | **5001**（HTTP 是 5000） |
| 包管理器 | Debian `apt` | **没有 apt**，需要 Entware 或自备二进制 |
| nginx 配置 | `/usr/trim/nginx/conf/` | `/etc/nginx/` + `/usr/syno/etc/www/`（需探测） |
| 证书存储 | 直接给 nginx 文件 | **`/usr/syno/etc/certificate/_archive/<ID>/`**，由 DSM 证书系统管理 |
| 服务管理 | `systemctl` | DSM 7 用 `/usr/syno/bin/synosystemctl`，DSM 6 用 `synoservice` |
| 反向代理 | 手写 nginx | **控制面板 → 登录门户 → 高级 → 反向代理**（图形化） |
| 定时任务 | crontab | **控制面板 → 任务计划**（图形化，建议用它） |

**最重要的差异**：群晖的证书不要直接塞给 nginx，而是走 DSM 的证书系统（`_archive` 目录 + `SYNO.Core.Certificate` API）。否则：
- 控制面板里看不到这张证书
- DSM 某些服务（如 Drive、Photos）不会用它
- DSM 系统更新时可能被重置

所以群晖方案用 **acme.sh 的 `synology_dsm` 部署钩子**，它通过 DSM API 正规导入证书，一次配置永久有效。

---

## 1. 最终架构

```
浏览器 ──https://nasv6.example.cn:5001──▶ NAS(公网 IPv6 直连) ──▶ DSM nginx :5001
                    │
                    ├─ DNS 层：Cloudflare AAAA 记录
                    │   由 /volume1/scripts/cf-ddns6.sh 每 5 分钟对齐（任务计划触发）
                    │
                    └─ 证书层：Let's Encrypt 通配符 *.example.cn
                        acme.sh（DNS-01）自动续期
                        → synology_dsm 钩子调 DSM API 导入
                        → DSM 自动重启相关服务
```

---

## 2. 前置条件检查

### 2.1 开启 SSH

控制面板 → 终端机与 SNMP → 勾选「启动 SSH 功能」，端口记下（默认 22）。

用管理员账号登录（需要 root，执行 `sudo -i`）：

```bash
ssh 你的账号@NAS-IP
sudo -i
```

### 2.2 确认公网 IPv6

```bash
ip -6 addr show scope global | grep inet6
```

期望两类地址：

```
inet6 2409:xxxx:xxxx:xxxx::25c/64            ← 固定后缀，DNS 用这个
inet6 2409:xxxx:xxxx:xxxx:aaaa:bbbb:cccc:dddd/64   ← SLAAC 临时地址，忽略
```

> 群晖默认用 EUI-64 或隐私扩展生成地址。若没有固定后缀，可在「控制面板 → 网络 → 网络界面 → 局域网 → IPv6 → 手动设置」里设固定后缀，或在 DHCPv6/SLAAC 下使用「IPv6 稳定地址」。

### 2.3 确认 5001 外网可达

在另一台不相关设备上（手机热点）：

```powershell
Test-NetConnection nasv6.example.cn -Port 5001
```

不通就查两处：

- **路由器 IPv6 防火墙**（国内路由器默认全拦入站）
- **群晖防火墙**：控制面板 → 安全性 → 防火墙，确认 5001 对 IPv6 放行

### 2.4 探测 DSM 的实际路径（重要，不同版本有差异）

一次性收集环境信息，后面每一步都会用到：

```bash
echo "== DSM 版本 =="; cat /etc.defaults/VERSION 2>/dev/null | grep -E 'productversion|build'

echo "== nginx 二进制 =="; readlink -f /proc/$(pgrep -o nginx)/exe

echo "== nginx 启动参数 =="; tr '\0' ' ' < /proc/$(pgrep -o nginx)/cmdline; echo

echo "== 证书存储 =="; ls -la /usr/syno/etc/certificate/_archive/ 2>/dev/null | head -20

echo "== 服务管理方式 =="; ls -l /usr/syno/bin/synosystemctl /usr/syno/sbin/synoservice 2>/dev/null

echo "== 可用工具 =="; for c in curl git jq bash openssl python3; do printf '%-8s %s\n' "$c" "$(command -v $c || echo 缺失)"; done
```

本手册后续命令中的路径若与你的实际不同，以这次探测结果为准。

---

## 3. 第 1 步：创建 Cloudflare API Token

**这一步在干什么**：acme.sh 要用 DNS-01 验证域名所有权——通过 Cloudflare API 临时写一条 TXT 记录，Let's Encrypt 查到即证明域名归你。所以需要一枚只能改 DNS 的凭据。

### 操作

1. https://dash.cloudflare.com → 右上头像 → **我的个人资料** → **API 令牌**
2. **创建令牌** → 模板 **「编辑区域 DNS」** → 使用模板
3. 确认权限是**两行**：

| 类型 | 资源 | 级别 |
|---|---|---|
| 区域 | DNS | 编辑 |
| 区域 | 区域 | **读取** ← 缺这行会报 9109 |

4. 区域资源 → **特定区域** → `example.cn`（不要选「所有区域」）
5. TTL、IP 筛选留空 → 创建 → **点复制按钮**（只显示一次）

### 立即验证

```bash
CF_TOKEN='粘贴令牌'
echo "长度: ${#CF_TOKEN}"     # 45 位左右；多几位说明混进了换行空格

curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer $CF_TOKEN"; echo

curl -s "https://api.cloudflare.com/client/v4/zones?name=example.cn" \
  -H "Authorization: Bearer $CF_TOKEN" | head -c 300; echo
```

两条都要 `"success":true`，第二条还要能看到 `"name":"example.cn"`。

> ⚠️ 令牌必须带 `cfut_` 前缀，少了会报 `1000 Invalid API Token`。**验证不通过不要往下走**，否则后面所有自动化都会静默失败。

---

## 4. 第 2 步：安装 acme.sh（群晖没有 apt）

**这一步在干什么**：acme.sh 是纯 shell 的 ACME 客户端，比 certbot 更适合群晖——它自带 `synology_dsm` 部署钩子，能直接调 DSM API 导入证书。

### 方案 A：从 Gitee 镜像克隆（推荐，绕开 get.acme.sh 被墙）

```bash
# 群晖自带 git 可能缺失，先看
command -v git

# 有 git：
git clone --depth 1 https://gitee.com/acmesh/acme.sh.git /volume1/@acme/acme.sh \
  || git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /volume1/@acme/acme.sh
```

装到系统可写的持久目录（`/volume1/@acme` 不会被 DSM 更新清掉）：

```bash
cd /volume1/@acme/acme.sh
./acme.sh --install --home /volume1/@acme/.acme.sh \
  --accountemail "你的邮箱@example.com"
```

验证：

```bash
/volume1/@acme/.acme.sh/acme.sh --version
```

> ⚠️ **不要用 `curl https://get.acme.sh | sh`**：该域名在部分网络会被 TLS 阻断（`Recv failure: Connection reset by peer`）。

> ⚠️ **不要装到 `/root`**：群晖的 `/root` 在系统分区，DSM 大版本更新可能被重置。用 `/volume1/...`。

### 方案 B：若 git 也没有

在电脑上下载 acme.sh 的 zip 包（Gitee 仓库 → 克隆/下载 → 下载 ZIP），通过 DSM 的 File Station 上传到 `/volume1/@acme/`，解压后执行上面的 `--install`。

---

## 5. 第 3 步：签发通配符证书（DNS-01）

**这一步在干什么**：签一张覆盖 `*.example.cn` 和 `example.cn` 的证书，放行所有子域名。

先备份一份 Cloudflare 凭据给 acme.sh：

```bash
export CF_Token='你的 cfut_ 令牌'
export CF_Account_ID=''      # 可留空
export CF_Zone_ID=''         # 可留空，acme.sh 会自动查（需要「区域读取」权限）
```

签发：

```bash
ACME=/volume1/@acme/.acme.sh/acme.sh

$ACME --issue --dns dns_cf \
  -d '*.example.cn' -d example.cn \
  --keylength ec-256 \
  --server letsencrypt \
  --force
```

参数说明：

| 参数 | 作用 |
|---|---|
| `--dns dns_cf` | 用 Cloudflare 插件做 DNS-01 验证 |
| `-d '*.example.cn' -d example.cn` | 通配符不覆盖裸域名，要单独加 |
| `--keylength ec-256` | ECC 证书，比 RSA 小且快 |
| `--server letsencrypt` | 指定 Let's Encrypt（不写会走 ZeroSSL，需注册账号） |

成功输出：

```
Your cert is in: /volume1/@acme/.acme.sh/*.example.cn_ecc/*.example.cn.cer
Cert success.
```

---

## 6. 第 4 步：把证书导入 DSM（全自动）

**这一步在干什么**：通过 DSM 的 WebAPI 把证书装进 DSM 证书系统，等价于在控制面板里点「导入证书」，但可以脚本化、可免人工。

acme.sh 内置 `synology_dsm` 钩子，只需要提供 DSM 管理员账号信息。

### 6.1 准备一个专用管理员账号（建议）

控制面板 → 用户与群组 → 新增用户 → 加入 `administrators` 组，勾选「禁止更改密码」（防止过期）。

> 为什么单独建账号：脚本里要明文存密码，避免用你自己的主账号。

### 6.2 执行部署

```bash
ACME=/volume1/@acme/.acme.sh/acme.sh

export SYNO_HOSTNAME='127.0.0.1'      # 本机验证，走 loopback 更稳
export SYNO_PORT='5001'
export SYNO_SCHEME='https'
export SYNO_USERNAME='acme-deploy'    # 专用管理员账号
export SYNO_PASSWORD='该账号的密码'
# 若账号开了两步验证，再加：
# export SYNO_OTP_CODE='123456'
# export SYNO_DEVICE_NAME='acme'      # 首次登录会注册设备名

$ACME --deploy -d '*.example.cn' --deploy-hook synology_dsm
```

成功时会打印该证书在 DSM 里的 ID：

```
Cert: /volume1/@acme/.acme.sh/*.example.cn_ecc/*.example.cn.cer
synology_dsm deploy success, cert id: XXXXXXXXX
```

然后到 **控制面板 → 安全性 → 证书** 里确认多了一张 `*.example.cn`。

### 6.3 绑定到服务

**控制面板 → 安全性 → 证书 → 设置**，把「DSM 桌面服务」（以及需要用到该证书的其他服务，如 Drive、Photos）指向新证书。

> 通配符证书覆盖 `example.cn` 本身，所以裸域名也能用，不必另配。

### 6.4 如果这条钩子失败

按报错对症：

| 报错 | 原因 | 处理 |
|---|---|---|
| `Login failed` | 账号/密码错，或账号非管理员 | 检查账号是否在 administrators 组 |
| `OTP code required` | 账号开了两步验证 | 加 `SYNO_OTP_CODE`，或用未开 2FA 的专用账号 |
| `API not found` | DSM 版本较老，API 路径不同 | 改用方案 B（下面） |
| `Permission denied` | 账号没有证书管理权限 | 用 administrators 组账号 |

**备用方案（手动导入，每 90 天一次）**：

```bash
ACME=/volume1/@acme/.acme.sh/acme.sh
mkdir -p /volume1/certs-out
$ACME --install-cert -d '*.example.cn' --ecc \
  --key-file       /volume1/certs-out/privkey.key \
  --fullchain-file /volume1/certs-out/fullchain.crt \
  --reloadcmd      "echo '请到 DSM 控制面板导入新证书'"
```

然后 控制面板 → 安全性 → 证书 → 新增 → 导入证书，选 `/volume1/certs-out/` 下的 `fullchain.crt` + `privkey.key`。

> ⚠️ 手动导入后记得**删掉 `/volume1/certs-out/privkey.key`**，私钥别长期放在共享目录。

---

## 7. 第 5 步：让 AAAA 记录自动跟随 IPv6

**这一步在干什么**：运营商重拨后 IPv6 前缀会变，域名必须跟着变，否则外网访问中断。

> 群晖自带的 DDNS（控制面板 → 外部访问 → DDNS）对 Cloudflare 支持有限、且主要针对 IPv4，这里用脚本更可控。

### 7.1 部署脚本（不依赖 jq）

```bash
mkdir -p /volume1/scripts
tee /volume1/scripts/cf-ddns6.sh > /dev/null <<'SCRIPT'
#!/bin/bash
# 群晖 IPv6 DDNS：把子域名的 AAAA 对齐到 NAS 当前固定后缀 IPv6
# 不依赖 jq，纯 grep/sed 解析 Cloudflare 返回

CF_TOKEN='在此填入 cfut_ 令牌'
ZONE_NAME='example.cn'
NAME='nasv6.example.cn'
IPV6_SUFFIX='::25c'          # NAS 固定后缀，用 ip -6 addr 确认

IP6=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | grep "${IPV6_SUFFIX}$" | head -1)
[ -z "$IP6" ] && { echo "$(date '+%F %T') 未取到 IPv6（后缀 $IPV6_SUFFIX），跳过"; exit 0; }

API='https://api.cloudflare.com/client/v4'
AUTH="Authorization: Bearer $CF_TOKEN"

ZONE_ID=$(curl -s "$API/zones?name=$ZONE_NAME" -H "$AUTH" \
  | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4)
[ -z "$ZONE_ID" ] && { echo "$(date '+%F %T') 取 Zone ID 失败（Token 无效或缺区域读取权限）"; exit 1; }

RESP=$(curl -s -H "$AUTH" "$API/zones/$ZONE_ID/dns_records?type=AAAA&name=$NAME")
REC_ID=$(echo "$RESP" | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4)
CUR=$(echo "$RESP"    | grep -o '"content":"[^"]*"'        | head -1 | cut -d'"' -f4)

if [ "$CUR" = "$IP6" ]; then echo "$(date '+%F %T') 无变化 $IP6"; exit 0; fi

if [ -z "$REC_ID" ]; then
  curl -s -X POST "$API/zones/$ZONE_ID/dns_records" -H "$AUTH" -H 'Content-Type: application/json' \
    --data "{\"type\":\"AAAA\",\"name\":\"$NAME\",\"content\":\"$IP6\",\"ttl\":120,\"proxied\":false}" >/dev/null
  echo "$(date '+%F %T') 已创建 AAAA -> $IP6"
else
  curl -s -X PATCH "$API/zones/$ZONE_ID/dns_records/$REC_ID" -H "$AUTH" -H 'Content-Type: application/json' \
    --data "{\"content\":\"$IP6\",\"ttl\":120}" >/dev/null
  echo "$(date '+%F %T') 已更新 $CUR -> $IP6"
fi
SCRIPT

chmod 700 /volume1/scripts/cf-ddns6.sh
```

> 为什么放在 `/volume1/scripts`：群晖的系统分区很小，且 DSM 更新可能清空系统目录；`/volume1` 是数据卷，安全。

### 7.2 首次执行

```bash
/volume1/scripts/cf-ddns6.sh
```

期望 `已创建 AAAA -> 2409:...` 或 `无变化 ...`。

### 7.3 加入定时任务（用图形界面）

**控制面板 → 任务计划 → 新增 → 计划的任务 → 用户定义的脚本**

| 字段 | 填什么 |
|---|---|
| 任务名称 | `cf-ddns6` |
| 用户 | **root** |
| 计划 | 每天 → 或在「重复」里选每 5 分钟 |
| 脚本 | `/volume1/scripts/cf-ddns6.sh >> /volume1/scripts/cf-ddns6.log 2>&1` |

> 群晖的 crontab 可以用，但图形界面更稳（DSM 更新会保留任务），且能看到上次执行结果与输出。

### 7.4 去 Cloudflare 核对

`nasv6` 下只应有**一条** AAAA，指向当前 IPv6，**代理状态 = 仅 DNS（灰云）**。

> ⚠️ 必须灰云：Cloudflare 代理只放行 80/443 等固定端口，5001 会被拦。这就是之前「打开域名超时、直连 IP 却正常」的原因。

---

## 8. 第 6 步：自动续期

**这一步在干什么**：证书 90 天过期，需要自动续。acme.sh 在 `--install` 时已经装了 cron 任务；`--deploy` 时记录的钩子会在续期后自动重新部署。

### 8.1 确认续期任务存在

```bash
crontab -l | grep acme
```

应有一行类似：

```
17 0 * * * "/volume1/@acme/.acme.sh"/acme.sh --cron --home "/volume1/@acme/.acme.sh" > /dev/null
```

群晖的 root crontab 在 `/etc/crontab`，若看不到，用图形界面加一条：

```
0 3 * * * /volume1/@acme/.acme.sh/acme.sh --cron --home /volume1/@acme/.acme.sh > /dev/null 2>&1
```

### 8.2 演练续期（不会真的换证书）

```bash
ACME=/volume1/@acme/.acme.sh/acme.sh
$ACME --renew -d '*.example.cn' --ecc --dry-run
```

### 8.3 确认部署钩子已记录

```bash
grep -E 'Le_DeployHook|Le_Webroot|Le_Keylength' /volume1/@acme/.acme.sh/*.example.cn_ecc/*.conf
```

期望看到 `Le_DeployHook='synology_dsm'` —— 有这行，续期后就会自动导入 DSM。

---

## 9. 第 7 步：验收

```bash
# 1) 证书有效期
/volume1/@acme/.acme.sh/acme.sh --info -d '*.example.cn'

# 2) DSM 中的证书列表（应能看到 *.example.cn）
ls -la /usr/syno/etc/certificate/_archive/

# 3) 本地验证服务端证书
echo | openssl s_client -connect 127.0.0.1:5001 -servername nasv6.example.cn 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# 4) DDNS 脚本
/volume1/scripts/cf-ddns6.sh
```

外网验证（另一台设备）：

```powershell
Test-NetConnection nasv6.example.cn -Port 5001
# 浏览器打开 https://nasv6.example.cn:5001
```

> ⚠️ 浏览器若仍显示「不安全」，**先清站点 cookie 或用无痕窗口**——之前证明过，服务端正常但浏览器缓存了旧证书会话时也会报不安全。

---

## 10. 群晖特有配置

### 10.1 强制 HTTPS

控制面板 → **网络 → DSM 设置** → 勾选「自动将 HTTP 连接重新导向 HTTPS」。这样 5000 端口会自动跳 5001。

### 10.2 关闭 5000 的公网访问

控制面板 → 安全性 → 防火墙 → 编辑规则：5000 只允许内网网段，5001 允许全部。

### 10.3 自定义域名访问

控制面板 → **登录门户 → DSM → 自定义域**，填 `nasv6.example.cn`，这样其他服务（如 Drive 客户端）会用它生成链接。

### 10.4 反向代理其他服务

控制面板 → **登录门户 → 高级 → 反向代理**，可以给 5666（fnOS）、8080（qBittorrent）等加子域名：

| 来源 | 目标 |
|---|---|
| `pan.example.cn` / 443 / HTTPS | `localhost:8080` / HTTP |
| `fnos.example.cn` / 443 / HTTPS | `192.168.x.x:5666` / HTTP |

这样一台群晖可以做整个局域网的统一入口（但注意这样会把内部服务也暴露到公网，按需开放）。

### 10.5 安全基线

- [ ] 停用默认 `admin` 账号，改用自定义管理员名
- [ ] 开启两步验证：控制面板 → 安全性 → 账户 → 两步验证
- [ ] 开启自动封锁：安全性 → 账户 → 自动封锁（5 次失败封 1 小时）
- [ ] 关闭 5000 明文端口外网访问
- [ ] Cloudflare 令牌最小权限 + 定期轮换
- [ ] 私钥/凭据不长期放在共享目录

---

## 11. 故障对照表

| 现象 | 根因 | 处理 |
|---|---|---|
| `1000 Invalid API Token` | 令牌缺 `cfut_` 前缀 / 抄错 / 已删除 | 重建令牌，先 `curl verify` |
| `9109 Invalid access token` | ① 令牌无效 ② 缺「区域·区域·读取」 | 补权限后重试 |
| `get.acme.sh` 下载失败 `Connection reset` | 域名被 TLS 阻断 | 用 Gitee 镜像 `git clone` |
| `--deploy synology_dsm` 报 Login failed | 账号非管理员或密码错 | 用 administrators 组账号 |
| 报 `OTP code required` | 账号开了两步验证 | 加 `SYNO_OTP_CODE` 或用专用账号 |
| DSM 证书列表里没有新证书 | 部署失败，只是签发成功 | 看 `--deploy` 的输出；或走手动导入 |
| 浏览器「不安全」 | ① 缺中间证书 ② 浏览器缓存 | 用 fullchain；清 cookie/无痕 |
| 域名超时、直连 IP 正常 | AAAA 过期 或 记录开了橙云 | 跑 DDNS 脚本；把记录改成灰云 |
| 5001 从外网连不上 | 路由器 IPv6 防火墙 / DSM 防火墙 | 两处都放行 5001 |
| 证书 90 天后失效 | 续期任务没跑 或 部署钩子没记录 | `crontab -l | grep acme`；查 `.conf` 里 `Le_DeployHook` |

---

## 12. 换机/重装速查

核心变量：

```bash
DOMAIN='example.cn'
SUB='nasv6'
EMAIL='你的邮箱@example.com'
CF_TOKEN='cfut_xxxx'
IPV6_SUFFIX='::25c'
```

要改的位置：

| 文件/位置 | 改什么 |
|---|---|
| `/volume1/scripts/cf-ddns6.sh` | `CF_TOKEN`、`ZONE_NAME`、`NAME`、`IPV6_SUFFIX` |
| acme.sh 的 `export CF_Token` | 每个新 shell 都要重新 export（或写进 `/volume1/@acme/.acme.sh/account.conf`） |
| `synology_dsm` 部署 | `SYNO_USERNAME` / `SYNO_PASSWORD` |
| DSM 控制面板 → 证书 → 设置 | 把服务指向新证书 |
| 任务计划 | 脚本路径 |

---

## 附：群晖 vs 飞牛 命令对照

| 操作 | 群晖 | 飞牛 |
|---|---|---|
| nginx 二进制 | 探测：`readlink -f /proc/$(pgrep -o nginx)/exe` | `/usr/trim/nginx/sbin/nginx` |
| nginx 配置 | `/etc/nginx/` + `/usr/syno/etc/www/` | `/usr/trim/nginx/conf/` |
| 重载服务 | `/usr/syno/bin/synosystemctl restart nginx`（DSM7）<br>`synoservice --restart nginx`（DSM6） | `systemctl reload trim_nginx` |
| 证书目录 | `/usr/syno/etc/certificate/_archive/<ID>/` | `/usr/trim/nginx/conf/`（含 SNI 文件） |
| 证书导入方式 | DSM API（`synology_dsm` 钩子）或控制面板 | 直接写文件 |
| 持久目录建议 | `/volume1/...` | `/root`、`/usr/local/bin` |
| 定时任务 | 控制面板 → 任务计划 | `crontab -e` |
