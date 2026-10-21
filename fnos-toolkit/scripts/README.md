# scripts

| 文件 | 用途 | 依赖 |
|---|---|---|
| `cf-ddns6.sh` | Cloudflare IPv6 DDNS：把子域名的 AAAA 对齐到 NAS 当前固定后缀 IPv6 | `curl` `jq` |
| `alidns-ddns6.sh` | 阿里云云解析版本：RPC + HMAC-SHA1 签名实现 | `curl` `openssl` |
| `fnos-sync.sh` | certbot 续期后把证书写入飞牛 nginx（含 SNI 合并文件）并 reload | `bash` |
| `fnos-sync-aliyun.sh` | 同上，读取 acme.sh 的证书路径 | `bash` |
| `netwatch.sh` | 网络看门狗：分层探测 + 状态机 + 邮件 + Worker 微信 + 心跳 | `bash` `curl` `ping` `msmtp` |
| `heartbeat-worker.js` | Cloudflare Worker：心跳接收、超时告警、统一通知出口 | Cloudflare Workers |

## 使用前必改

```bash
# cf-ddns6.sh / alidns-ddns6.sh
CF_TOKEN='...'        # 或 AK/SK
ZONE_NAME='example.com'
NAME='nas.example.com'
IPV6_SUFFIX='::25c'

# fnos-sync.sh
LIVE="/etc/letsencrypt/live/example.com"
CONF="/usr/trim/nginx/conf"
SNI_FILE="$CONF/nas.example.com"
NGINX_SERVICE="trim_nginx"

# netwatch.sh 通过 /etc/netwatch.conf 配置，见 examples/
```

## 权限约定

```bash
chmod 700 /usr/local/bin/*.sh                    # 可执行脚本
chmod 600 /etc/netwatch.conf /root/.secrets/*.ini # 含密钥的配置
```
