#!/bin/bash
# ============================================================
# 群晖 Synology DSM · Cloudflare IPv6 DDNS 脚本
# 作用：把指定子域名的 AAAA 记录对齐到 NAS 当前的固定后缀 IPv6
# 特点：不依赖 jq（群晖默认没有），纯 grep/sed 解析 Cloudflare 返回
#
# 部署：
#   mkdir -p /volume1/scripts
#   cp cf-ddns6.sh /volume1/scripts/cf-ddns6.sh
#   chmod 700 /volume1/scripts/cf-ddns6.sh
#
# 定时（推荐用图形界面）：
#   控制面板 → 任务计划 → 新增 → 计划的任务 → 用户定义的脚本
#   用户：root   计划：每 5 分钟
#   脚本：/volume1/scripts/cf-ddns6.sh >> /volume1/scripts/cf-ddns6.log 2>&1
#
# 手动测试：/volume1/scripts/cf-ddns6.sh
# ============================================================

# ---------- 需要修改的变量 ----------
CF_TOKEN='在此填入你的 cfut_ 令牌'
ZONE_NAME='example.cn'
NAME='nasv6.example.cn'
IPV6_SUFFIX='::25c'          # NAS 固定后缀地址的后缀，用 ip -6 addr show scope global 确认
# -----------------------------------

IP6=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | grep "${IPV6_SUFFIX}$" | head -1)
if [ -z "$IP6" ]; then
  echo "$(date '+%F %T') 未取到可用 IPv6（后缀 ${IPV6_SUFFIX}），跳过"
  exit 0
fi

API='https://api.cloudflare.com/client/v4'
AUTH="Authorization: Bearer $CF_TOKEN"

# 查 Zone ID（Cloudflare 返回的是紧凑 JSON，用 grep 抓 32 位十六进制 id）
ZONE_ID=$(curl -s "$API/zones?name=$ZONE_NAME" -H "$AUTH" \
  | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4)
if [ -z "$ZONE_ID" ]; then
  echo "$(date '+%F %T') 取 Zone ID 失败（Token 无效或缺「区域读取」权限）"
  exit 1
fi

RESP=$(curl -s -H "$AUTH" "$API/zones/$ZONE_ID/dns_records?type=AAAA&name=$NAME")
REC_ID=$(echo "$RESP" | grep -o '"id":"[a-f0-9]\{32\}"' | head -1 | cut -d'"' -f4)
CUR=$(echo "$RESP"    | grep -o '"content":"[^"]*"'        | head -1 | cut -d'"' -f4)

if [ "$CUR" = "$IP6" ]; then
  echo "$(date '+%F %T') 无变化 $IP6"
  exit 0
fi

if [ -z "$REC_ID" ]; then
  curl -s -X POST "$API/zones/$ZONE_ID/dns_records" -H "$AUTH" -H 'Content-Type: application/json' \
    --data "{\"type\":\"AAAA\",\"name\":\"$NAME\",\"content\":\"$IP6\",\"ttl\":120,\"proxied\":false}" >/dev/null
  echo "$(date '+%F %T') 已创建 AAAA -> $IP6"
else
  curl -s -X PATCH "$API/zones/$ZONE_ID/dns_records/$REC_ID" -H "$AUTH" -H 'Content-Type: application/json' \
    --data "{\"content\":\"$IP6\",\"ttl\":120}" >/dev/null
  echo "$(date '+%F %T') 已更新 $CUR -> $IP6"
fi
