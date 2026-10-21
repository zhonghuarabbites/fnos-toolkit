# 从 Cloudflare 迁移到阿里云云解析 · 操作手册

> 编写时间：2026-10-21
> 适用：域名在阿里云注册、当前 NS 指向 Cloudflare、已有可用的 NAS HTTPS 访问
> 迁移后：DNS 由阿里云云解析托管，DDNS 与证书改用阿里云 API

---

## 0. 先决策：值不值得迁

| 维度 | Cloudflare（现状） | 阿里云云解析 |
|---|---|---|
| 费用 | 免费 | 免费版 0 元；个人版 48 元/年；企业旗舰版 568 元/年 |
| TTL 下限 | 60 秒（可 auto） | 免费版 **600 秒**，付费版更低 |
| API 凭据 | API Token，可限定「单区域 + 仅 DNS 编辑」 | RAM 子账号 AccessKey + 自定义策略 |
| 证书客户端 | certbot + 官方 `dns-cloudflare` | acme.sh + `dns_ali`（certbot 的阿里云插件是第三方） |
| 国内解析质量 | `.cn` 域名用境外 NS，部分网络偏慢 | 国内节点，通常更快 |
| 修改工作量 | — | 改 NS + 改 DDNS 脚本 + 换证书客户端，约 1 小时（外加 24–48h 等 NS 生效） |

**结论**：

- 若只是「域名在阿里云所以想用阿里云」→ 不建议动，现有方案已跑通且免费；
- 若遇到**国内解析慢、偶发解析失败**→ 值得迁，按本文操作；
- 若在意 IPv6 变更后的生效速度（TTL 600 秒 vs 60 秒）→ 保持 Cloudflare，或买付费版把 TTL 降到 60 秒。

---

## 1. 迁移总览

```
① 备份现有 DNS 记录
② 阿里云建 RAM 子账号 + AccessKey
③ 在阿里云云解析里建好同样的记录（此时还不生效）
④ 切换 NS（域名控制台 → 使用阿里云 DNS）
⑤ 等 24–48 小时传播，验证解析
⑥ 部署阿里云版 DDNS 脚本，停用 Cloudflare 版
⑦ 证书改用 acme.sh dns_ali，并接到飞牛 nginx
⑧ 验收
```

**关键顺序**：先建记录 → 再切 NS → 再换脚本/证书。顺序颠倒会出现「解析空窗」。

---

## 2. 第 ① 步：备份现有 DNS 记录

在电脑上执行，把 Cloudflare 当前的记录抄下来：

```powershell
Resolve-DnsName nas.example.com -Type AAAA
Resolve-DnsName nas.example.com -Type A
Resolve-DnsName example.com -Type A
Resolve-DnsName example.com -Type AAAA
```

同时在 Cloudflare 的 DNS 页面**截图**（记得看清代理状态是灰云还是橙云）。

---

## 3. 第 ② 步：创建 RAM 子账号与 AccessKey

**为什么不用主账号**：主账号 AccessKey 等于整个阿里云账号的所有权限（能买资源、能删数据）。子账号可以单独禁用。

1. 登录阿里云 → **访问控制 RAM** → 用户 → **创建用户**
2. 勾选 **OpenAPI 调用访问**（会生成 AccessKey，只显示一次，记下来）
3. 给这个用户 **自定义策略**（不要直接给 `AliyunDNSFullAccess`，权限过大）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:DescribeDomainRecords",
        "alidns:DescribeDomainRecordInfo",
        "alidns:AddDomainRecord",
        "alidns:UpdateDomainRecord"
      ],
      "Resource": ["*"]
    }
  ]
}
```

> DNS 记录类操作在阿里云侧不支持资源级授权，`Resource` 只能写 `*`；但通过「只给这四个 Action」，已经杜绝了删域名、买资源等危险操作。

4. 记下 **AccessKey ID**（`LTAI...` 开头）和 **AccessKey Secret**

---

## 4. 第 ③ 步：在阿里云云解析里建好记录

进入 **云解析 DNS 控制台** → 找到 `example.com`（首次使用需点「解析设置」，阿里云会自动分配 NS 给你）

添加记录：

| 记录类型 | 主机记录 | 记录值 | TTL |
|---|---|---|---|
| AAAA | `nasv6` | NAS 当前 IPv6（如 `2409:xxxx:xxxx:xxxx::25c`） | 600 |
| AAAA | `@`（可选，裸域名） | 同上 | 600 |

> 这一步只是**在阿里云侧准备好数据**，此时公网仍走 Cloudflare，不影响现有访问。

---

## 5. 第 ④ 步：切换 NS

阿里云 **域名控制台 → 我的域名 → example.com → DNS 修改 → 使用阿里云 DNS**，点确定。

阿里云会给出 NS 列表，通常是：

```
ns1.alidns.com
ns2.alidns.com
```

> 若提示「默认使用阿里云 DNS」则无需操作，只要把 DNS 服务器从 Cloudflare 改回阿里云即可。

### 注意事项

- **不要立刻删 Cloudflare 的记录**，等 NS 完全生效（24–48 小时）后再清理，否则个别缓存未过期的递归服务器会解析失败；
- 期间可以用以下命令观察传播进度：

```powershell
Resolve-DnsName nas.example.com -Type AAAA -Server 223.5.5.5
Resolve-DnsName nas.example.com -Type AAAA -Server 8.8.8.8
```

两个公共 DNS 都返回阿里云侧的值，说明生效了。

---

## 6. 第 ⑥ 步：换 DDNS 脚本

Cloudflare 版（`cf-ddns6.sh`）用的是 Bearer Token + REST；阿里云是 RPC + HMAC-SHA1 签名，脚本要换。

### 6.1 部署新脚本

把随包的 `alidns-ddns6.sh` 传到 NAS：

```bash
mkdir -p /volume1/scripts        # 群晖；飞牛可用 /usr/local/bin
# 用 File Station / scp 上传后：
mv alidns-ddns6.sh /usr/local/bin/cf-ddns6.sh     # 沿用旧文件名，定时任务不用改
chmod 700 /usr/local/bin/cf-ddns6.sh
```

编辑脚本顶部四个变量：

```bash
AK='LTAI5txxxxxxxxxxxxxxxx'
SK='AccessKeySecretxxxxxxxxxxxx'
DOMAIN='example.com'
RR='nasv6'
IPV6_SUFFIX='::25c'
```

### 6.2 先手动跑一次

```bash
/usr/local/bin/cf-ddns6.sh
```

期望：

```
2026-10-21 20:12:33 无变化 2409:xxxx:xxxx:xxxx::25c
```

或 `已更新 ... -> ...`。

失败时的报错含义：

| 输出 | 原因 |
|---|---|
| `查询失败: Specified signature is not matched with our calculation.` | AccessKey Secret 不对，或系统时间偏差超过 15 分钟 |
| `查询失败: InvalidAccessKeyId.NotFound` | AccessKey ID 写错 |
| `查询失败: Forbidden.RAM` | 子账号没有对应权限，检查策略 JSON |
| `未取到可用 IPv6` | 网卡上找不到 `::25c` 后缀地址，检查 `IPV6_SUFFIX` |
| `签名计算失败` | 缺 openssl（`apt install -y openssl`） |

> 时间偏差是签名失败的常见原因：`date -u` 与真实 UTC 差超过 15 分钟就会被拒。用 `timedatectl set-ntp true` 校正。

### 6.3 定时任务沿用

原来那条 `*/5 * * * * /usr/local/bin/cf-ddns6.sh ...` 不用改（文件名没变）。

---

## 7. 第 ⑦ 步：证书改用 acme.sh

阿里云 DNS 的 certbot 插件是第三方（`certbot-dns-alidns`，要 pip 装），在飞牛/群晖上都不好折腾。**acme.sh 原生支持 `dns_ali`**，更省事。

### 7.1 安装 acme.sh

```bash
# 不要用 get.acme.sh（部分网络被 TLS 阻断）
git clone --depth 1 https://gitee.com/acmesh/acme.sh.git /opt/acme.sh \
  || git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /opt/acme.sh

/opt/acme.sh/acme.sh --install --home /root/.acme.sh \
  --accountemail "you@example.com"
```

### 7.2 签发通配符证书

```bash
export Ali_Key='LTAI5txxxxxxxxxxxxxxxx'
export Ali_Secret='AccessKeySecretxxxxxxxxxxxx'

/root/.acme.sh/acme.sh --issue --dns dns_ali \
  -d '*.example.com' -d example.com \
  --keylength ec-256 --server letsencrypt
```

> acme.sh 会把 `Ali_Key` / `Ali_Secret` 记到 `/root/.acme.sh/account.conf`，后续续期不用再 export。

### 7.3 安装到固定位置并接上部署钩子

先把随包的 `fnos-sync-aliyun.sh` 放到 NAS：

```bash
mkdir -p /root/scripts /root/certs
# 上传 fnos-sync-aliyun.sh 后：
mv fnos-sync-aliyun.sh /root/scripts/fnos-sync-aliyun.sh
chmod 700 /root/scripts/fnos-sync-aliyun.sh
```

然后让 acme.sh 把证书装到 `/root/certs/`，并在每次安装/续期后调用钩子：

```bash
/root/.acme.sh/acme.sh --install-cert -d example.com --ecc \
  --key-file       /root/certs/wildcard.key \
  --fullchain-file /root/certs/wildcard.crt \
  --reloadcmd      "bash /root/scripts/fnos-sync-aliyun.sh"
```

这条命令会立即执行一次 `reloadcmd`，所以**跑完证书就已经写进 nginx 了**。

验证：

```bash
bash /root/scripts/fnos-sync-aliyun.sh
echo | openssl s_client -showcerts -connect 127.0.0.1:5667 -servername nas.example.com 2>/dev/null | grep -c 'BEGIN CERTIFICATE'
```

期望 `4`（叶子 + 中间 + 根 + 交叉签名）。

### 7.4 停用 certbot（可选但建议）

```bash
systemctl disable --now certbot.timer
systemctl disable --now certbot-renew.timer 2>/dev/null || true
```

> 留着也不会冲突（两套证书互不干扰），但确认 acme.sh 续期正常后再关掉更清晰。
> 想彻底清理：`apt remove --purge certbot python3-certbot-dns-cloudflare`，并删除 `/etc/letsencrypt`。

### 7.5 确认续期自动化

```bash
crontab -l | grep acme          # 应有 acme.sh --cron 的任务
grep -E 'Le_DeployHook|Le_ReloadCmd' /root/.acme.sh/example.com_ecc/example.com.conf
```

> `Le_ReloadCmd` 里应该是 `bash /root/scripts/fnos-sync-aliyun.sh` —— 有它，续期后会自动部署。

演练：

```bash
/root/.acme.sh/acme.sh --renew -d example.com --ecc --dry-run
```

---

## 8. 第 ⑧ 步：验收

```bash
# 1) 解析走阿里云
dig +short AAAA nas.example.com @223.5.5.5
dig +short NS example.com @223.5.5.5        # 应返回 ns1/ns2.alidns.com

# 2) DDNS 脚本
/usr/local/bin/cf-ddns6.sh

# 3) 证书
/root/.acme.sh/acme.sh --info -d example.com | head -15
echo | openssl s_client -showcerts -connect 127.0.0.1:5667 -servername nas.example.com 2>/dev/null | grep -c 'BEGIN CERTIFICATE'

# 4) 续期
/root/.acme.sh/acme.sh --renew -d example.com --ecc --dry-run | tail -3
```

外网最终验证（另一台设备）：

```powershell
Test-NetConnection nas.example.com -Port 5667
# 浏览器 https://nas.example.com:5667，锁头正常
```

---

## 9. 回滚方案

任何一步出问题都能退：

| 出问题的环节 | 回滚动作 |
|---|---|
| 解析不正常 | 域名控制台把 NS 改回 Cloudflare（`<你的NS1>.ns.cloudflare.com` / `<你的NS2>.ns.cloudflare.com`），等 24–48h；Cloudflare 上的记录如果没删，立刻恢复 |
| DDNS 脚本报错 | 换回 Cloudflare 版脚本（令牌还在的话），或先手动改记录应急 |
| 证书签发失败 | 现有证书仍有 90 天有效期，不影响访问；修好 acme.sh 再签 |
| 证书部署出错 | `cp /usr/trim/nginx/conf/server.crt.bak.<日期> ...` 恢复并 `systemctl reload trim_nginx` |

> 因此**迁移期间绝对不要删 Cloudflare 上的记录**，这就是你的回滚底牌。

---

## 10. Cloudflare vs 阿里云 脚本对照

| 项目 | Cloudflare 版 | 阿里云版 |
|---|---|---|
| 查询记录 | `GET /zones/{id}/dns_records?type=AAAA&name=...` | `DescribeDomainRecords`（RPC） |
| 新增 | `POST .../dns_records` | `AddDomainRecord` |
| 更新 | `PATCH .../dns_records/{id}` | `UpdateDomainRecord` |
| 认证 | `Authorization: Bearer <token>` | `AccessKeyId` + HMAC-SHA1 签名 |
| 依赖 | curl + jq | curl + openssl（无需 jq） |
| 生效粒度 | 记录级 | 记录级 |
| 幂等 | 是 | 是（脚本先查后改） |

---

## 11. 费用速查

| 项目 | 价格 |
|---|---|
| 云解析 DNS 免费版 | 0 元（TTL 最低 600 秒，功能足够本方案） |
| 云解析 DNS 个人版 | 48 元/年 |
| 云解析 DNS 企业旗舰版 | 568 元/年 |
| DNS 安全防护（可选加购） | 基础防御 600 元/年；全力防御 3000 元/年 |

计费公式：**总价 = (实例版本单价 + 安全防护单价) × 主域名数量**

> 本方案只用 AAAA 记录 + API 更新，**免费版完全够用**，无需付费。若嫌 TTL 600 秒太长（IPv6 变更后最多 10 分钟才全网生效），才考虑升级版本把 TTL 降下来。

---

## 12. 常见问题

**Q：换了 NS，原来的 Cloudflare 免费功能（CDN、防护）还有吗？**
A：没有了。但本方案是**纯 DNS 直连**（记录本来就是灰云、不走 Cloudflare 代理），所以没有任何功能损失。

**Q：需要备案吗？**
A：备案与 DNS 服务商无关，取决于你的接入方式。用非标准端口（5667/5001）自用一般无实际影响，但**对外提供网站服务按法规应备案**，自行评估。

**Q：IPv6 前缀变了，多久生效？**
A：脚本每 5 分钟检测一次，写进阿里云后受 TTL 影响：免费版 600 秒，即最坏情况约 15 分钟内全网更新。

**Q：能不能同时挂两家 DNS 做冗余？**
A：域名只能有一组 NS。想冗余得用支持「多 DNS 商同步」的服务（如 DNSpod 的混合云方案），成本远高于收益，家宽场景不必。
