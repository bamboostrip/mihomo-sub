#!/bin/sh

CONFIG_DIR="/root/.config/mihomo"
INIT_DIR="/usr/share/mihomo-init"
SUB_URLS_FILE="${CONFIG_DIR}/sub_urls.txt"
SCHEDULE_FILE="${CONFIG_DIR}/schedule.conf"
SECRET_FILE="${CONFIG_DIR}/.secret"
mkdir -p "${CONFIG_DIR}"

# 本机探测绕开代理（避免 http_proxy 指向自身 7890 时自环）
curl_local() {
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl "$@"
}

# ---------------------------
# API 密钥持久化（移植自上游 3.0.0，但默认空 = 无密码，保持本 fork 旧行为）
# 上游 3.0.0 留空会生成随机密钥（破坏性变更）；本 fork 留空即无密码，
# 只有显式设置 SECRET 才启用鉴权，避免老用户升级后被锁在面板外。
# ---------------------------
case "${SECRET}" in
    off|OFF|none|NONE|false|FALSE|disable|DISABLE|disabled|DISABLED)
        SECRET=""
        : > "${SECRET_FILE}"
        ;;
    "")
        if [ -f "${SECRET_FILE}" ] && [ -s "${SECRET_FILE}" ]; then
            SECRET=$(tr -d '[:space:]' < "${SECRET_FILE}" 2>/dev/null)
        else
            SECRET=""
        fi
        ;;
    *)
        mkdir -p "${CONFIG_DIR}"
        printf '%s' "${SECRET}" > "${SECRET_FILE}"
        chmod 600 "${SECRET_FILE}" 2>/dev/null || true
        ;;
esac
export SECRET
if [ -n "${SECRET}" ]; then
    echo "🔑 已启用 API 密钥鉴权"
else
    echo "🔓 未设置 SECRET，面板无密码（仅建议局域网使用）"
fi

# ---------------------------
# 管理页面密码（可选，Basic 鉴权；保护 :9091 页面与 CGI API）
# MGR_PASSWORD 环境变量 > 数据卷持久化文件；留空 = 无密码（保持旧行为），off = 显式关闭
# 用户名 MGR_USER（默认 admin）
# ---------------------------
MGR_USER=$(printf '%s' "${MGR_USER:-admin}" | tr -d ':\r\n')
[ -n "${MGR_USER}" ] || MGR_USER=admin
MGR_PASSWORD_FILE="${CONFIG_DIR}/.mgr_password"
case "${MGR_PASSWORD}" in
    off|OFF|none|NONE|false|FALSE|disable|DISABLE|disabled|DISABLED)
        MGR_PASSWORD=""
        : > "${MGR_PASSWORD_FILE}" 2>/dev/null || true
        rm -f "${CONFIG_DIR}/httpd.conf" 2>/dev/null || true
        ;;
    "")
        if [ -f "${MGR_PASSWORD_FILE}" ] && [ -s "${MGR_PASSWORD_FILE}" ]; then
            MGR_PASSWORD=$(head -1 "${MGR_PASSWORD_FILE}" 2>/dev/null)
        else
            MGR_PASSWORD=""
        fi
        ;;
    *)
        printf '%s' "${MGR_PASSWORD}" > "${MGR_PASSWORD_FILE}"
        chmod 600 "${MGR_PASSWORD_FILE}" 2>/dev/null || true
        ;;
esac
if [ -n "${MGR_PASSWORD}" ]; then
    echo "🔐 管理页面将启用密码（用户 ${MGR_USER}）"
else
    echo "🔓 管理页面无密码（仅建议局域网使用）"
fi

# ---------------------------
# 配置文件初始化
# ---------------------------
mkdir -p "${CONFIG_DIR}"

# 首次运行或空目录挂载时，从内置目录复制初始文件
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    cp "${INIT_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
    echo "📄 初始化 mihomo 配置"
fi

# SECRET 同步进 config.yaml：存在则替换、没有则追加（sub.sh 每次刷新同样会强制写入）。
# 不能只在“缺少时才追加”：改密钥/去掉密钥后，配置里的旧 secret 与新值不一致，
# 启动探测会一直 401/403 → 容器重启循环；而 sub.sh 要等探测通过才会运行，无法自愈。
# 收敛成函数：下面启动前校验失败回退后，要对新配置重跑一遍，保证鉴权行为一致
sync_secret() {
    SECRET_ESC=$(printf '%s' "${SECRET}" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if grep -qE '^secret:' "${CONFIG_DIR}/config.yaml" 2>/dev/null; then
        SECRET_ESC="${SECRET_ESC}" awk '
            /^secret:/ { print "secret: \"" ENVIRON["SECRET_ESC"] "\""; next }
            { print }
        ' "${CONFIG_DIR}/config.yaml" > "${CONFIG_DIR}/config.yaml.tmp" && \
            mv "${CONFIG_DIR}/config.yaml.tmp" "${CONFIG_DIR}/config.yaml"
    else
        printf 'secret: "%s"\n' "${SECRET_ESC}" >> "${CONFIG_DIR}/config.yaml"
    fi
}
sync_secret

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
# 启动前先校验数据卷里的 config.yaml：坏配置（如上次断电留下的半成品）会让核心
# 起不来 → 探测 10 次失败 → exit 1 → docker 无限重启（重启死循环，
# 此时 sub.sh 永远没机会运行自愈）。校验失败先备份坏文件供排查，
# 再回退：good 优先，否则用内置初始配置；回退后的新文件重跑 secret 同步
if command -v timeout >/dev/null 2>&1; then MT="timeout 30"; else MT=""; fi
t_err=$(${MT} /mihomo -t -d "${CONFIG_DIR}" -f "${CONFIG_DIR}/config.yaml" 2>&1)
t_rc=$?
if [ "${t_rc}" -ne 0 ]; then
    t_msg=$(printf '%s' "${t_err}" | grep -iE 'error|fail' | tail -1)
    [ -n "${t_msg}" ] || t_msg="exit ${t_rc}"
    echo "❌ config.yaml 未通过 mihomo 校验（${t_msg}），已备份为 config.yaml.bad 并回退"
    cp -f "${CONFIG_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml.bad"
    if [ -f "${CONFIG_DIR}/config.yaml.good" ]; then
        cp -f "${CONFIG_DIR}/config.yaml.good" "${CONFIG_DIR}/config.yaml"
        echo "↩️ 已回退到上一份可用配置（config.yaml.good）"
    else
        cp "${INIT_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
        echo "↩️ 没有 good 备份，已回退到内置初始配置"
    fi
    sync_secret
fi

echo "🚀 启动 mihomo..."
/mihomo &
sleep 2

# 等待 mihomo 就绪
# 注意：设置 SECRET 后无鉴权请求返回 401，curl -f 会判失败，
# 所以探测必须带 Authorization 头；同时探测 /version 端点
# （根路径 / 行为不可靠），与 healthcheck.sh 保持一致
mihomo_ready=false
for i in $(seq 1 10); do
    probe_ok=false
    if [ -n "${SECRET}" ]; then
        if curl_local -sf --max-time 3 -H "Authorization: Bearer ${SECRET}" \
            http://127.0.0.1:9090/version > /dev/null 2>&1; then
            probe_ok=true
        fi
    else
        if curl_local -sf --max-time 3 \
            http://127.0.0.1:9090/version > /dev/null 2>&1; then
            probe_ok=true
        fi
    fi
    if $probe_ok; then
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
    if curl_local -s -o /dev/null "http://127.0.0.1:25500/version" 2>/dev/null; then
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
# 端口：MGMT_PORT（默认 9091；network_mode: host 下 -p 映射不生效，用这个改）
# 密码：MGR_PASSWORD 设置后启用 Basic 鉴权（哈希用 base busybox 的 cryptpw 生成）
# ---------------------------
MGMT_PORT="${MGMT_PORT:-9091}"
case "${MGMT_PORT}" in
    ''|*[!0-9]*) MGMT_PORT=9091 ;;
esac
HTTPD_ARGS=""
if [ -n "${MGR_PASSWORD}" ]; then
    MGR_HASH=$(cryptpw -m md5 -- "${MGR_PASSWORD}" 2>/dev/null)
    if [ -n "${MGR_HASH}" ]; then
        HTTPD_CONF="${CONFIG_DIR}/httpd.conf"
        printf '/:%s:%s\n' "${MGR_USER}" "${MGR_HASH}" > "${HTTPD_CONF}"
        chmod 600 "${HTTPD_CONF}" 2>/dev/null || true
        HTTPD_ARGS="-c ${HTTPD_CONF}"
        echo "🔐 管理页面鉴权已开启（用户 ${MGR_USER}）"
    else
        echo "⚠️ cryptpw 生成密码哈希失败，管理页面未启用密码"
    fi
fi
echo "🌐 启动管理页面 http://0.0.0.0:${MGMT_PORT}"
busybox-extras httpd -h /usr/share/mihomo-mgr -p "${MGMT_PORT}" ${HTTPD_ARGS}

# ---------------------------
# 启动 cron
# ---------------------------
echo "⏰ 启动定时任务..."
exec crond -f
