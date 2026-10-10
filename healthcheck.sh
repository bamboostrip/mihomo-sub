#!/bin/sh
# 健康检查：读取运行时写入的密钥，避免设置 SECRET 后裸探 /version 误报不健康
# 移植自上游 pure-white-ice-cream/mihomo-sub 3.0.0 的 healthcheck.sh，
# 端口沿用本 fork 的 9090（上游用 CONTROLLER_PORT 环境变量，本镜像固定 9090）。

CONFIG_DIR="/root/.config/mihomo"
SECRET=""

# 本机探测绕开代理：容器设了 http_proxy 且 no_proxy 不含 127.0.0.1 时，
# 裸 curl 会绕道 mihomo 自身再去探 127.0.0.1:9090，误判不健康（与 init.sh 同款）
curl_local() {
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl "$@"
}

if [ -f "${CONFIG_DIR}/.secret" ]; then
    SECRET=$(tr -d '[:space:]' < "${CONFIG_DIR}/.secret" 2>/dev/null)
fi

if [ -n "${SECRET}" ]; then
    curl_local -fsS --max-time 5 -H "Authorization: Bearer ${SECRET}" \
        "http://127.0.0.1:9090/version" > /dev/null
else
    curl_local -fsS --max-time 5 "http://127.0.0.1:9090/version" > /dev/null
fi
