#!/bin/bash
# ============================================================
# 群晖 Synology · acme.sh 签发 + DSM 自动部署 一键脚本
#
# 用法：改好下面变量后执行
#   chmod 700 /volume1/scripts/acme-dsm-deploy.sh
#   /volume1/scripts/acme-dsm-deploy.sh
#
# 前置：
#   1. 已安装 acme.sh 到 /volume1/@acme/.acme.sh（见部署手册第 4 步）
#   2. 已在 DSM 建好专用管理员账号（administrators 组）
#   3. Cloudflare 令牌已验证可用（32 位 Zone + 两行权限）
# ============================================================
set -euo pipefail

# ---------- 需要修改的变量 ----------
DOMAIN='example.cn'                       # 主域名
ACME_HOME='/volume1/@acme/.acme.sh'
ACME="$ACME_HOME/acme.sh"

CF_TOKEN='cfut_在此填入令牌'
CF_ACCOUNT_ID=''                          # 可留空
CF_ZONE_ID=''                             # 可留空（需要区域读取权限）

SYNO_HOSTNAME='127.0.0.1'
SYNO_PORT='5001'
SYNO_SCHEME='https'
SYNO_USERNAME='acme-deploy'               # DSM 专用管理员账号
SYNO_PASSWORD='该账号密码'
SYNO_OTP_CODE=''                          # 账号开了两步验证时填，否则留空
SYNO_DEVICE_NAME='acme'                   # 首次登录注册的设备名
# -----------------------------------

[ -x "$ACME" ] || { echo "找不到 acme.sh：$ACME，请先按手册第 4 步安装"; exit 1; }

export CF_Token="$CF_TOKEN"
[ -n "$CF_ACCOUNT_ID" ] && export CF_Account_ID="$CF_ACCOUNT_ID"
[ -n "$CF_ZONE_ID" ]    && export CF_Zone_ID="$CF_ZONE_ID"

echo "== 1/2 签发通配符证书 =="
"$ACME" --issue --dns dns_cf \
  -d "*.${DOMAIN}" -d "${DOMAIN}" \
  --keylength ec-256 \
  --server letsencrypt \
  --force

echo
echo "== 2/2 部署到 DSM =="
export SYNO_HOSTNAME SYNO_PORT SYNO_SCHEME SYNO_USERNAME SYNO_PASSWORD
[ -n "$SYNO_OTP_CODE" ]    && export SYNO_OTP_CODE
[ -n "$SYNO_DEVICE_NAME" ] && export SYNO_DEVICE_NAME

"$ACME" --deploy -d "*.${DOMAIN}" --deploy-hook synology_dsm

echo
echo "== 完成 =="
echo "到 控制面板 → 安全性 → 证书 确认新证书存在，"
echo "再到 证书 → 设置 把 DSM 桌面服务指向它。"
echo
echo "续期检查："
"$ACME" --info -d "*.${DOMAIN}" | head -20
echo
echo "部署钩子记录（应有 Le_DeployHook='synology_dsm'）："
grep -E 'Le_DeployHook|Le_Keylength' "$ACME_HOME"/*.${DOMAIN}_ecc/*.conf 2>/dev/null || true
