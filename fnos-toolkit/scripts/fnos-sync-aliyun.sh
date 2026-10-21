#!/bin/bash
# ============================================================
# 飞牛 NAS · acme.sh 证书部署钩子（阿里云解析版）
#
# 与 Cloudflare 版的区别：证书来源从 certbot 换成 acme.sh，
# 所以证书路径不同（acme.sh --install-cert 的落点）。
#
# 部署：/root/scripts/fnos-sync-aliyun.sh，chmod 700
# 触发：acme.sh --install-cert 的 --reloadcmd 调用它；
#       acme.sh 续期成功后会自动重新执行 --install-cert 的钩子。
# ============================================================
set -e

# ---------- 需要修改的变量 ----------
CERT_DIR="/root/certs"                        # acme.sh --install-cert 的落点
CRT="$CERT_DIR/wildcard.crt"                  # fullchain
KEY="$CERT_DIR/wildcard.key"                  # privkey
CONF="/usr/trim/nginx/conf"                   # 飞牛 nginx 配置目录
SNI_FILE="$CONF/nas.example.com"             # 必须与访问域名完全一致
NGINX_SERVICE="trim_nginx"                    # systemctl list-units | grep nginx
# -----------------------------------

[ -f "$CRT" ] || { echo "找不到证书: $CRT"; exit 1; }
[ -f "$KEY" ] || { echo "找不到私钥: $KEY"; exit 1; }

# 1. nginx 默认路径（证书链 + 私钥）
cat "$CRT" > "$CONF/server.crt"
cp  "$KEY"  "$CONF/server.key"
chmod 644 "$CONF/server.crt"
chmod 600 "$CONF/server.key"

# 2. SNI 动态路径（证书链与私钥合并的单文件，$ssl_server_name 读的就是它）
cat "$CRT" "$KEY" > "$SNI_FILE"
chmod 600 "$SNI_FILE"

# 3. 重载服务（trim_nginx 的 ExecStartPre 自带 nginx -t 校验）
systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE"

echo "$(date '+%F %T') fnos-sync: certificate deployed, $NGINX_SERVICE reloaded"
