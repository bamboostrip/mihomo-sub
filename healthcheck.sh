#!/bin/sh
# 健康检查：读取运行时写入的密钥，避免设置 SECRET 后裸探 /version 误报不健康
# 移植自上游 pure-white-ice-cream/mihomo-sub 3.0.0 的 healthcheck.sh，
# 端口沿用本 fork 的 9090（上游用 CONTROLLER_PORT 环境变量，本镜像固定 9090）。

CONFIG_DIR="/root/.config/mihomo"
SECRET=""

if [ -f "${CONFIG_DIR}/.secret" ]; then
    SECRET=$(tr -d '[:space:]' < "${CONFIG_DIR}/.secret" 2>/dev/null)
fi

if [ -n "${SECRET}" ]; then
    curl -fsS --max-time 5 -H "Authorization: Bearer ${SECRET}" \
        "http://127.0.0.1:9090/version" > /dev/null
else
    curl -fsS --max-time 5 "http://127.0.0.1:9090/version" > /dev/null
fi
