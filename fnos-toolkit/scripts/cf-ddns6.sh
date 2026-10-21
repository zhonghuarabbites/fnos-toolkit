#!/usr/bin/env bash
# ============================================================
# 飞牛 NAS · Cloudflare IPv6 DDNS 脚本
# 作用：把指定子域名的 AAAA 记录对齐到 NAS 当前的固定后缀 IPv6
# 部署：/usr/local/bin/cf-ddns6.sh，chmod 700
# 定时：*/5 * * * * /usr/local/bin/cf-ddns6.sh >> /var/log/cf-ddns6.log 2>&1
# 依赖：jq（apt install -y jq）
# ============================================================
set -euo pipefail

# ---------- 需要修改的变量 ----------
CF_TOKEN='在此填入你的 cfut_ 令牌'
ZONE_NAME='example.com'
NAME='nas.example.com'
IPV6_SUFFIX='::25c'          # NAS 固定后缀地址的后缀，用 ip -6 addr 确认
# -----------------------------------

# 取固定后缀的 IPv6（避开会轮换的 SLAAC 长地址）
IP6=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | grep "${IPV6_SUFFIX}$" | head -1)
if [ -z "${IP6:-}" ]; then
  echo "$(date '+%F %T') 未取到可用 IPv6（后缀 ${IPV6_SUFFIX}），跳过"
  exit 0
fi

API_BASE='https://api.cloudflare.com/client/v4'
ZONE_ID=$(curl -s "$API_BASE/zones?name=$ZONE_NAME" \
  -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id // empty')
if [ -z "$ZONE_ID" ]; then
  echo "$(date '+%F %T') 取 Zone ID 失败（Token 无效或缺区域读取权限）"
  exit 1
fi

API="$API_BASE/zones/$ZONE_ID/dns_records"
RESP=$(curl -s -H "Authorization: Bearer $CF_TOKEN" "$API?type=AAAA&name=$NAME")
REC_ID=$(echo "$RESP" | jq -r '.result[0].id // empty')
CUR=$(echo "$RESP"    | jq -r '.result[0].content // empty')

if [ "$CUR" = "$IP6" ]; then
  echo "$(date '+%F %T') 无变化 $IP6"
  exit 0
fi

if [ -z "$REC_ID" ]; then
  curl -s -X POST "$API" -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
    --data "{\"type\":\"AAAA\",\"name\":\"$NAME\",\"content\":\"$IP6\",\"ttl\":120,\"proxied\":false}" >/dev/null
  echo "$(date '+%F %T') 已创建 AAAA -> $IP6"
else
  curl -s -X PATCH "$API/$REC_ID" -H "Authorization: Bearer $CF_TOKEN" -H 'Content-Type: application/json' \
    --data "{\"content\":\"$IP6\",\"ttl\":120}" >/dev/null
  echo "$(date '+%F %T') 已更新 $CUR -> $IP6"
fi
