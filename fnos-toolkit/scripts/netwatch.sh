#!/bin/bash
# ============================================================
# 飞牛 NAS · 网络看门狗 v3
#
# 职责（只管探测与判定，通知外包）：
#   1. 分层探测：默认网关 / 公网 IPv4 / 公网 IPv6 / DNS
#   2. 状态机：连续 N 次失败才判定断网，过滤抖动
#   3. 事件：断网、恢复（含中断时长）、降级（IPv6 丢 / DNS 坏）
#   4. 通知：① 本地 msmtp 发邮件（可靠，不依赖 Cloudflare）
#            ② 调 Cloudflare Worker /notify 发微信
#            两者并行，任一成功即算送达
#   5. 心跳：每次运行 GET Worker 的 /ping，供「NAS 完全离线」场景兜底
#
# 部署：/usr/local/bin/netwatch.sh（chmod 700）
# 配置：/etc/netwatch.conf（chmod 600）
# 定时：* * * * * /usr/local/bin/netwatch.sh >> /var/log/netwatch-cron.log 2>&1
# 自测：/usr/local/bin/netwatch.sh test
# ============================================================
set -uo pipefail

CONF="${NETWATCH_CONF:-/etc/netwatch.conf}"
[ -f "$CONF" ] && . "$CONF"

# ---------- 默认值（被 /etc/netwatch.conf 覆盖）----------
: "${NODE_NAME:=fnos}"
: "${TARGET_V4:=223.5.5.5}"
: "${TARGET_V4_ALT:=119.29.29.29}"
: "${TARGET_V6:=2400:3200::1}"
: "${TARGET_V6_ALT:=2402:4e00::}"
: "${DNS_NAME:=www.baidu.com}"
: "${FAIL_THRESHOLD:=3}"
: "${STATE_DIR:=/var/lib/netwatch}"
: "${LOG_FILE:=/var/log/netwatch.log}"
: "${HEARTBEAT_URL:=}"
: "${NOTIFY_URL:=}"
: "${MAIL_TO:=}"
: "${MAIL_FROM:=}"
: "${MAIL_CMD:=msmtp}"
: "${MAIL_ACCOUNT:=qq}"
: "${DEGRADED_RENOTIFY:=3600}"

mkdir -p "$STATE_DIR" 2>/dev/null

# ---------- 基础函数 ----------
log() { echo "$(date '+%F %T') [$NODE_NAME] $*" >> "$LOG_FILE"; }

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//'; }

uptime_str() {
  local s=$1
  if [ "$s" -ge 3600 ]; then echo "$((s/3600)) 小时 $((s%3600/60)) 分钟"
  elif [ "$s" -ge 60 ]; then echo "$((s/60)) 分钟"
  else echo "$s 秒"; fi
}

# ---------- 通知：本地邮件 ----------
notify_mail() {
  local subject="$1" body="$2"
  [ -z "$MAIL_TO" ] && return 1
  command -v "$MAIL_CMD" >/dev/null 2>&1 || return 1
  local to ok=0
  for to in $MAIL_TO; do
    printf 'Subject: [%s] %s\nFrom: %s\nTo: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
      "$NODE_NAME" "$subject" "$MAIL_FROM" "$to" "$body" \
      | "$MAIL_CMD" -a "$MAIL_ACCOUNT" "$to" >/dev/null 2>&1 || ok=1
  done
  return $ok
}

# ---------- 通知：经 Worker 发微信 ----------
notify_worker() {
  local subject="$1" body="$2"
  [ -z "$NOTIFY_URL" ] && return 1
  local payload
  payload=$(printf '{"title":"%s","body":"%s"}' "$(json_esc "$subject")" "$(json_esc "$body")")
  curl -s -m 15 -X POST "$NOTIFY_URL" \
    -H 'Content-Type: application/json' --data "$payload" | grep -q 'sent:'
}

# ---------- 统一告警：邮件 + 微信并行 ----------
alert() {
  local subject="$1" body="$2" ok=1
  notify_mail   "$subject" "$body" && ok=0
  notify_worker "$subject" "$body" && ok=0
  if [ "$ok" = 0 ]; then log "告警已发送：$subject"; else log "告警发送失败：$subject"; fi
  return $ok
}

# ---------- 探测 ----------
probe_gateway() {
  local gw
  gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
  [ -z "$gw" ] && return 1
  ping -c1 -W2 "$gw" >/dev/null 2>&1
}

probe_v4() {
  ping -c1 -W2 "$TARGET_V4"     >/dev/null 2>&1 && return 0
  ping -c1 -W2 "$TARGET_V4_ALT" >/dev/null 2>&1 && return 0
  return 1
}

probe_v6() {
  local v6ping="ping6"
  command -v ping6 >/dev/null 2>&1 || v6ping="ping -6"
  $v6ping -c1 -W2 "$TARGET_V6"     >/dev/null 2>&1 && return 0
  $v6ping -c1 -W2 "$TARGET_V6_ALT" >/dev/null 2>&1 && return 0
  return 1
}

probe_dns() { getent hosts "$DNS_NAME" >/dev/null 2>&1; }

# ---------- 状态 ----------
read_state() { cat "$STATE_DIR/status" 2>/dev/null || echo "up"; }
write_state() { echo "$1" > "$STATE_DIR/status"; }
get_counter() { cat "$STATE_DIR/fail_count" 2>/dev/null || echo 0; }
set_counter() { echo "$1" > "$STATE_DIR/fail_count"; }

# ---------- 子命令：test ----------
if [ "${1:-}" = "test" ]; then
  echo "发送测试通知（邮件 + 微信）..."
  if alert "通道测试" "这是一条测试消息，收到说明通道正常。时间：$(date '+%F %T')"; then
    echo "✅ 已发出（本地邮件 / Worker 微信，至少一条成功）"
    exit 0
  else
    echo "❌ 全部通道失败，检查 MAIL_* 与 NOTIFY_URL"
    exit 1
  fi
fi

# ---------- 主流程 ----------
gw_ok=0; v4_ok=0; v6_ok=0; dns_ok=0
probe_gateway && gw_ok=1
probe_v4      && v4_ok=1
probe_v6      && v6_ok=1
probe_dns     && dns_ok=1

if [ "$v4_ok" = 1 ] || [ "$v6_ok" = 1 ]; then online=1; else online=0; fi

prev=$(read_state)
count=$(get_counter)

if [ "$online" = 1 ]; then
  # 心跳：让外部知道 NAS 还活着
  if [ -n "$HEARTBEAT_URL" ]; then
    curl -s -m 8 "$HEARTBEAT_URL" >/dev/null 2>&1 || log "心跳发送失败"
  fi
  set_counter 0

  if [ "$prev" = "down" ]; then
    down_since=$(cat "$STATE_DIR/down_since" 2>/dev/null || echo 0)
    dur=$(( $(date +%s) - down_since ))
    write_state up
    rm -f "$STATE_DIR/pending_notify"
    log "恢复正常，中断约 $(uptime_str $dur)"
    alert "网络已恢复" "中断时长约 $(uptime_str $dur)。当前：IPv4=$v4_ok IPv6=$v6_ok DNS=$dns_ok"
  elif [ -f "$STATE_DIR/pending_notify" ]; then
    rm -f "$STATE_DIR/pending_notify"
    down_since=$(cat "$STATE_DIR/down_since" 2>/dev/null || echo 0)
    dur=$(( $(date +%s) - down_since ))
    log "补发断网告警（中断约 $(uptime_str $dur)）"
    alert "网络曾中断（补发）" "中断时长约 $(uptime_str $dur)，现已恢复。"
  fi

  # 降级告警
  degraded=""
  [ "$v4_ok" = 1 ] && [ "$v6_ok" = 0 ] && degraded="IPv6 不可用"
  [ "$dns_ok" = 0 ] && degraded="${degraded:+$degraded；}DNS 解析异常"

  if [ -n "$degraded" ]; then
    last=$(cat "$STATE_DIR/last_degraded" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ $((now - last)) -ge "$DEGRADED_RENOTIFY" ]; then
      echo "$now" > "$STATE_DIR/last_degraded"
      log "降级：$degraded"
      alert "网络降级：$degraded" "IPv4=$v4_ok IPv6=$v6_ok DNS=$dns_ok
如果是 IPv6 不可用，外网访问 https://nas.example.com 会受影响，请检查光猫/路由器的 IPv6 前缀。"
    fi
  else
    rm -f "$STATE_DIR/last_degraded"
  fi

else
  count=$((count + 1))
  set_counter "$count"
  log "探测失败 ${count}/${FAIL_THRESHOLD}（gw=$gw_ok v4=$v4_ok v6=$v6_ok dns=$dns_ok）"

  if [ "$count" -ge "$FAIL_THRESHOLD" ] && [ "$prev" != "down" ]; then
    write_state down
    date +%s > "$STATE_DIR/down_since"
    log "判定断网"
    if alert "网络中断" "连续 ${count} 次探测失败，NAS 无法访问外网。
网关=$gw_ok IPv4=$v4_ok IPv6=$v6_ok DNS=$dns_ok
（若本条刚到达，说明是网络恢复后补发的）"; then
      log "断网告警已发送"
    else
      touch "$STATE_DIR/pending_notify"
      log "断网告警发送失败，已标记待补发"
    fi
  fi
fi

exit 0
