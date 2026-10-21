#!/bin/bash
# ============================================================
# 阿里云云解析 DNS · IPv6 DDNS 脚本（不依赖 jq / python）
#
# 作用：把指定子域名的 AAAA 记录对齐到 NAS 当前的固定后缀 IPv6
# 依赖：curl、openssl（飞牛 / 群晖都自带）
#
# 凭据：RAM 子账号 AccessKey（不要用主账号），权限建议自定义策略：
#   dns:DescribeDomainRecords / dns:AddDomainRecord / dns:UpdateDomainRecord
#
# 部署：/usr/local/bin/cf-ddns6.sh（或 /volume1/scripts/cf-ddns6.sh）
#       chmod 700
# 定时：*/5 * * * * /path/cf-ddns6.sh >> /var/log/alidns-ddns.log 2>&1
#
# 手动测试：/usr/local/bin/cf-ddns6.sh
# ============================================================
set -uo pipefail

# ---------- 需要修改的变量 ----------
AK='LTAI5txxxxxxxxxxxxxxxx'        # RAM 子账号 AccessKey ID
SK='AccessKeySecretxxxxxxxxxxxx'   # AccessKey Secret
DOMAIN='example.com'                # 主域名（不带 www）
RR='nasv6'                         # 主机记录 = 子域名前缀
RTYPE='AAAA'
TTL='600'                          # 免费版最低 600 秒；付费版可更低
IPV6_SUFFIX='::25c'                # NAS 固定后缀地址的后缀
# -----------------------------------

API='https://alidns.aliyuncs.com/'
VERSION='2015-01-09'

# ---------- RFC3986 百分号编码 ----------
urlencode() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hx '%%%02X' "'$c"; out+="$hx" ;;
    esac
  done
  printf '%s' "$out"
}

# ---------- 调用阿里云 RPC 接口（HMAC-SHA1 签名）----------
# 用法：aliyun_rpc <Action> [Key=Value ...]
aliyun_rpc() {
  local action="$1"; shift

  local timestamp nonce
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  nonce=$(openssl rand -hex 16)

  local -a params=(
    "AccessKeyId=$AK"
    "Action=$action"
    "Format=JSON"
    "SignatureMethod=HMAC-SHA1"
    "SignatureNonce=$nonce"
    "SignatureVersion=1.0"
    "Timestamp=$timestamp"
    "Version=$VERSION"
  )
  while [ $# -gt 0 ]; do params+=("$1"); shift; done

  # 1) 按 key 字典序排序 → 逐项 URL 编码 → 拼成 canonicalized query string
  local cqs="" kv k v
  while IFS= read -r kv; do
    k="${kv%%=*}"
    v="${kv#*=}"
    cqs+="$(urlencode "$k")=$(urlencode "$v")&"
  done < <(printf '%s\n' "${params[@]}" | LC_ALL=C sort)
  cqs="${cqs%&}"

  # 2) stringToSign = GET & %2F & percentEncode(cqs)
  local sts="GET&%2F&$(urlencode "$cqs")"

  # 3) 签名 = Base64(HMAC-SHA1(secret + "&", stringToSign))
  local sig
  sig=$(printf '%s' "$sts" | openssl dgst -sha1 -hmac "${SK}&" -binary | openssl base64 -A)
  [ -z "$sig" ] && { echo "签名计算失败（openssl 不可用？）"; return 1; }

  curl -s "${API}?${cqs}&Signature=$(urlencode "$sig")"
}

# ---------- 取当前 IPv6 ----------
IP6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep "${IPV6_SUFFIX}$" | head -1)
if [ -z "${IP6:-}" ]; then
  echo "$(date '+%F %T') 未取到可用 IPv6（后缀 ${IPV6_SUFFIX}），跳过"
  exit 0
fi

# ---------- 查现有记录 ----------
RESP=$(aliyun_rpc DescribeDomainRecords \
  "DomainName=$DOMAIN" "RRKeyWord=$RR" "Type=$RTYPE" "PageSize=100")

if echo "$RESP" | grep -q '"Code"'; then
  echo "$(date '+%F %T') 查询失败：$(echo "$RESP" | grep -o '"Message":"[^"]*"' | head -1)"
  exit 1
fi

REC_ID=$(echo "$RESP" | grep -o '"RecordId":"[0-9]*"' | head -1 | cut -d'"' -f4)
CUR=$(echo "$RESP"    | grep -o '"Value":"[^"]*"'    | head -1 | cut -d'"' -f4)

if [ "$CUR" = "$IP6" ]; then
  echo "$(date '+%F %T') 无变化 $IP6"
  exit 0
fi

# ---------- 新增或更新 ----------
if [ -z "$REC_ID" ]; then
  RET=$(aliyun_rpc AddDomainRecord \
    "DomainName=$DOMAIN" "RR=$RR" "Type=$RTYPE" "Value=$IP6" "TTL=$TTL")
  if echo "$RET" | grep -q '"RecordId"'; then
    echo "$(date '+%F %T') 已创建 $RR.$DOMAIN -> $IP6"
  else
    echo "$(date '+%F %T') 创建失败：$(echo "$RET" | grep -o '"Message":"[^"]*"' | head -1)"
    exit 1
  fi
else
  RET=$(aliyun_rpc UpdateDomainRecord \
    "RecordId=$REC_ID" "RR=$RR" "Type=$RTYPE" "Value=$IP6" "TTL=$TTL")
  if echo "$RET" | grep -q '"RecordId"'; then
    echo "$(date '+%F %T') 已更新 $CUR -> $IP6"
  else
    echo "$(date '+%F %T') 更新失败：$(echo "$RET" | grep -o '"Message":"[^"]*"' | head -1)"
    exit 1
  fi
fi
