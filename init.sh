#!/bin/sh

CONFIG_DIR="/root/.config/mihomo"
INIT_DIR="/usr/share/mihomo-init"
SUB_URLS_FILE="${CONFIG_DIR}/sub_urls.txt"
SCHEDULE_FILE="${CONFIG_DIR}/schedule.conf"

# ---------------------------
# 配置文件初始化
# ---------------------------
mkdir -p "${CONFIG_DIR}"

# 首次运行或空目录挂载时，从内置目录复制初始文件
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    cp "${INIT_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
    echo "📄 初始化 mihomo 配置"
fi

if [ ! -d "${CONFIG_DIR}/ui" ] || [ -z "$(ls -A "${CONFIG_DIR}/ui" 2>/dev/null)" ]; then
    mkdir -p "${CONFIG_DIR}/ui"
    cp -a "${INIT_DIR}/ui/." "${CONFIG_DIR}/ui/"
    echo "🎨 初始化 Web 面板"
fi

# 复制预下载的地理库文件（避免启动时直连 GitHub 超时）
# 如果已有文件太小（<100KB，说明损坏），也重新复制
if [ -f "${INIT_DIR}/geoip.metadb" ]; then
    existing_size=$(wc -c < "${CONFIG_DIR}/geoip.metadb" 2>/dev/null || echo 0)
    if [ "${existing_size}" -lt 102400 ]; then
        cp "${INIT_DIR}/geoip.metadb" "${CONFIG_DIR}/geoip.metadb"
        echo "🗺 初始化 GeoIP 数据库"
    fi
fi
if [ -f "${INIT_DIR}/geosite.dat" ]; then
    existing_size=$(wc -c < "${CONFIG_DIR}/geosite.dat" 2>/dev/null || echo 0)
    if [ "${existing_size}" -lt 102400 ]; then
        cp "${INIT_DIR}/geosite.dat" "${CONFIG_DIR}/geosite.dat"
        echo "🗺 初始化 GeoSite 数据库"
    fi
fi

# 初始化订阅列表文件
if [ ! -f "${SUB_URLS_FILE}" ]; then
    if [ -n "${sub_url}" ]; then
        echo "${sub_url}" > "${SUB_URLS_FILE}"
        echo "📋 从环境变量初始化订阅列表"
    else
        touch "${SUB_URLS_FILE}"
    fi
fi

# 初始化调度配置
if [ ! -f "${SCHEDULE_FILE}" ]; then
    echo "daily" > "${SCHEDULE_FILE}"
    echo "⏱ 初始化调度配置: daily"
fi

# ---------------------------
# 启动 mihomo 核心
# ---------------------------
echo "🚀 启动 mihomo..."
/mihomo &
sleep 2

# 等待 mihomo 就绪
mihomo_ready=false
for i in $(seq 1 10); do
    if curl -sf --max-time 3 http://127.0.0.1:9090 > /dev/null 2>&1; then
        echo "✅ mihomo 已就绪"
        mihomo_ready=true
        break
    fi
    echo "⏳ 等待 mihomo 启动... (${i}/10)"
    sleep 1
done
if ! $mihomo_ready; then
    echo "❌ mihomo 启动超时，退出"
    exit 1
fi

# ---------------------------
# 启动 subconverter（先清缓存再启动）
# ---------------------------
echo "🔄 清理缓存并启动 subconverter..."
for d in /subconverter/cache /tmp/.subconverter_cache; do
    [ -d "${d}" ] && rm -rf "${d}"/* 2>/dev/null || true
done
/subconverter/subconverter &
sleep 2

# ---------------------------
# 等待 subconverter 就绪
# ---------------------------
subc_ready=false
for i in $(seq 1 10); do
    if curl -s -o /dev/null "http://127.0.0.1:25500/version" 2>/dev/null; then
        echo "✅ subconverter 已就绪"
        subc_ready=true
        break
    fi
    echo "⏳ 等待 subconverter 启动... (${i}/10)"
    sleep 1
done
if ! $subc_ready; then
    echo "❌ subconverter 启动超时，退出"
    exit 1
fi

# ---------------------------
# 首次订阅更新
# ---------------------------
echo "📡 执行首次订阅更新..."
/etc/periodic/15min/sub.sh --now

# ---------------------------
# 启动管理页面 (busybox httpd)
# ---------------------------
echo "🌐 启动管理页面 http://0.0.0.0:9091"
busybox-extras httpd -h /usr/share/mihomo-mgr -p 9091

# ---------------------------
# 启动 cron
# ---------------------------
echo "⏰ 启动定时任务..."
exec crond -f
