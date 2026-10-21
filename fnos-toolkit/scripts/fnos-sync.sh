#!/bin/bash
# ============================================================
# 飞牛 NAS · certbot 续期后自动部署证书
# 部署位置：/etc/letsencrypt/renewal-hooks/deploy/fnos-sync.sh
# 权限：chmod +x
# 触发：certbot 每次成功续期后自动执行（也可手动 bash 运行）
# ============================================================
set -e

# ---------- 需要修改的变量 ----------
LIVE="/etc/letsencrypt/live/example.com"   # 证书目录，名字 = 主域名
CONF="/usr/trim/nginx/conf"               # 飞牛 nginx 配置目录
SNI_FILE="$CONF/nas.example.com"         # 必须与访问域名完全一致
NGINX_SERVICE="trim_nginx"                # systemctl list-units | grep nginx
# -----------------------------------

# 1. nginx 默认路径（证书链 + 私钥分开存）
cat "$LIVE/fullchain.pem" > "$CONF/server.crt"
cp  "$LIVE/privkey.pem"    "$CONF/server.key"
chmod 644 "$CONF/server.crt"
chmod 600 "$CONF/server.key"

# 2. SNI 动态路径（证书链与私钥合并成单文件，$ssl_server_name 读的就是它）
cat "$LIVE/fullchain.pem" "$LIVE/privkey.pem" > "$SNI_FILE"
chmod 600 "$SNI_FILE"

# 3. 重载服务（trim_nginx 的 ExecStartPre 自带 nginx -t 校验）
systemctl reload "$NGINX_SERVICE" 2>/dev/null || systemctl restart "$NGINX_SERVICE"

echo "$(date '+%F %T') fnos-sync: certificate deployed, $NGINX_SERVICE reloaded"
