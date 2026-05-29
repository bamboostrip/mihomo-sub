#!/bin/sh

# ---------------------------
# 路径与变量
# ---------------------------
CONFIG_DIR="/root/.config/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
LOG_FILE="${CONFIG_DIR}/log.txt"
SUB_URLS_FILE="${CONFIG_DIR}/sub_urls.txt"
SCHEDULE_FILE="${CONFIG_DIR}/schedule.conf"
LAST_RUN_FILE="${CONFIG_DIR}/last_run"
UA_FILE="${CONFIG_DIR}/user_agent.txt"
TEMP_DIR="/tmp/mihomo_sub"

CR=$(printf '\r')
log=""
refresh_time=$(date +"%Y-%m-%d %H:%M:%S %z")

# User-Agent: 从文件读取，默认使用 mihomo 版本号
if [ -f "${UA_FILE}" ] && [ -s "${UA_FILE}" ]; then
    SUB_UA=$(head -1 "${UA_FILE}")
else
    SUB_UA="clash-verge/v2.5.1"
fi

# ---------------------------
# 检查是否为手动触发
# ---------------------------
FORCE=false
if [ "$1" = "--now" ]; then
    FORCE=true
fi

# ---------------------------
# 输出日志并退出
# ---------------------------
sub_end() {
    exit_code="${1:-0}"
    log="${log}\n"
    printf "%b" "${log}" >> "${LOG_FILE}"
    # 日志超过 1MB 时只保留最后 50KB
    if [ -f "${LOG_FILE}" ]; then
        log_size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "${log_size}" -gt 1048576 ]; then
            tail -c 51200 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
    # 清理临时目录
    rm -rf "${TEMP_DIR}"
    exit "${exit_code}"
}

# ---------------------------
# 检查调度时间
# ---------------------------
check_schedule() {
    if $FORCE; then
        return 0
    fi

    schedule=$(cat "${SCHEDULE_FILE}" 2>/dev/null | head -1)
    case "${schedule}" in
        "15min") interval=900 ;;
        "hourly") interval=3600 ;;
        "daily"|"") interval=86400 ;;
        *) interval=86400 ;;
    esac

    if [ -f "${LAST_RUN_FILE}" ]; then
        last=$(cat "${LAST_RUN_FILE}" 2>/dev/null)
        now=$(date +%s)
        if [ -n "${last}" ] && [ $((now - last)) -lt "${interval}" ]; then
            exit 0
        fi
    fi
    return 0
}

# ---------------------------
# 提取 YAML 区块
# ---------------------------
extract_section() {
    file="$1"
    section="$2"
    awk -v sec="${section}" '
        $0 ~ "^"sec":" { in_sec=1; next }
        in_sec && /^[a-z-]+:/ { exit }
        in_sec { print }
    ' "${file}"
}

# ---------------------------
# 日志输出辅助
# ---------------------------
check_schedule

# 清除 subconverter 缓存
for d in /subconverter/cache /tmp/.subconverter_cache; do
    [ -d "${d}" ] && rm -rf "${d}"/* 2>/dev/null || true
done

log="${log}[${refresh_time}] \n\t订阅文件更新...\n\t"

# ---------------------------
# 读取订阅列表
# ---------------------------
if [ ! -f "${SUB_URLS_FILE}" ] || [ ! -s "${SUB_URLS_FILE}" ]; then
    # 回退到环境变量
    if [ -n "${sub_url}" ]; then
        echo "${sub_url}" > "${SUB_URLS_FILE}"
    else
        log="${log}Error: 无订阅地址，请通过管理页面添加\n\t"
        sub_end 1
    fi
fi

# ---------------------------
# 创建临时目录
# ---------------------------
mkdir -p "${TEMP_DIR}"

# ---------------------------
# 处理每个订阅 URL
# ---------------------------
all_proxies=""
all_rules=""
first_groups=""
sub_count=0
success_count=0

while IFS= read -r line || [ -n "${line}" ]; do
    # 去除 Windows 换行符 \r
    line="${line%"${CR}"}"
    # 跳过注释和空行
    case "${line}" in
        ""|"#"*) continue ;;
    esac

    sub_count=$((sub_count + 1))
    sub_url="${line}"
    raw_file="${TEMP_DIR}/raw_${sub_count}.txt"
    temp_file="${TEMP_DIR}/sub_${sub_count}.yml"

    log="${log}第 ${sub_count} 个订阅获取中...\n\t"

    # curl 直接下载原始订阅，正确设置 User-Agent
    curl_exit=0
    curl -s --max-time 30 -H "User-Agent: ${SUB_UA}" -o "${raw_file}" "${sub_url}" || curl_exit=$?

    if [ "${curl_exit}" -ne 0 ]; then
        log="${log}Error: 订阅 ${sub_count} 下载失败，退出码: ${curl_exit}\n\t"
        continue
    fi

    if [ ! -s "${raw_file}" ]; then
        log="${log}Error: 订阅 ${sub_count} 返回空内容\n\t"
        continue
    fi

    # 判断原始内容格式：如果已经是 clash YAML 则直接使用
    if grep -qE '^proxies:' "${raw_file}" 2>/dev/null; then
        cp "${raw_file}" "${temp_file}"
        log="${log}订阅 ${sub_count} 已为 Clash 格式\n\t"
    else
        # 非 Clash 格式，通过 subconverter 转换
        encoded_sub_url=$(jq -rn --arg x "${sub_url}" '$x|@uri' 2>/dev/null)
        encoded_ua=$(jq -rn --arg x "${SUB_UA}" '$x|@uri' 2>/dev/null)
        http_code=$(curl -s --max-time 30 -w "%{http_code}" -o "${temp_file}" "http://127.0.0.1:25500/sub?target=clash&url=${encoded_sub_url}&ua=${encoded_ua}")
        curl_exit=$?

        if [ "${curl_exit}" -ne 0 ]; then
            log="${log}Error: 订阅 ${sub_count} 转换失败，退出码: ${curl_exit}\n\t"
            continue
        elif [ "${http_code}" -ne 200 ]; then
            log="${log}Error: 订阅 ${sub_count} 转换失败，响应码: ${http_code}\n\t"
            continue
        fi
    fi

    if [ ! -s "${temp_file}" ]; then
        log="${log}Error: 订阅 ${sub_count} 处理后为空\n\t"
        continue
    fi

    # 提取代理列表
    proxies=$(extract_section "${temp_file}" "proxies")
    if [ -n "${proxies}" ]; then
        all_proxies="${all_proxies}${proxies}
"
    fi

    # 提取规则
    rules=$(extract_section "${temp_file}" "rules")
    if [ -n "${rules}" ]; then
        all_rules="${all_rules}${rules}
"
    fi

    # 保留第一个订阅的 proxy-groups
    if [ -z "${first_groups}" ]; then
        first_groups=$(extract_section "${temp_file}" "proxy-groups")
    fi

    # 只有实际提取到代理或规则才算成功
    if [ -n "${proxies}" ] || [ -n "${rules}" ]; then
        success_count=$((success_count + 1))
        log="${log}订阅 ${sub_count} 更新成功\n\t"
    else
        log="${log}订阅 ${sub_count} 无有效节点\n\t"
    fi

done < "${SUB_URLS_FILE}"

if [ "${success_count}" -eq 0 ]; then
    log="${log}Error: 所有订阅均失败\n\t"
    sub_end 1
fi

# ---------------------------
# 构建最终配置文件（printf %s 不解释转义，订阅数据安全）
# ---------------------------
{
    printf '%s\n' 'mixed-port: 7890'
    printf '%s\n' 'external-ui: /root/.config/mihomo/ui'
    printf '%s\n' 'allow-lan: true'

    if [ -n "${all_proxies}" ]; then
        printf '%s\n' 'proxies:'
        printf '%s' "${all_proxies}"
    fi

    if [ -n "${first_groups}" ]; then
        printf '%s\n' 'proxy-groups:'
        printf '%s' "${first_groups}"
        echo
    else
        printf '%s\n' 'proxy-groups:'
        printf '%s\n' '  - name: Proxy'
        printf '%s\n' '    type: select'
        printf '%s\n' '    proxies:'
        printf '%s' "${all_proxies}" | awk '/^[[:space:]]*- name:/{ sub(/^[[:space:]]*- name:[[:space:]]*/, ""); print "      - " $0}'
        printf '%s\n' '      - DIRECT'
    fi

    if [ -n "${all_rules}" ]; then
        printf '%s\n' 'rules:'
        printf '%s' "${all_rules}"
    else
        printf '%s\n' 'rules:'
        printf '%s\n' '  - MATCH,DIRECT'
    fi

    printf '%s\n' 'external-controller: 0.0.0.0:9090'
} > "${CONFIG_FILE}"

if [ ! -s "${CONFIG_FILE}" ]; then
    log="${log}Error: 配置文件生成失败\n\t"
    sub_end 1
fi

log="${log}配置文件生成成功 (${success_count}/${sub_count} 个订阅) ✅\n\t"

# ---------------------------
# 配置重新加载
# ---------------------------
log="${log}配置重新加载...\n\t"
reload_response=$(curl -s --max-time 15 -w "%{http_code}" -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -d '{"path":"","payload":""}')
reload_exit_code=$?

if [ "${reload_exit_code}" -ne 0 ]; then
    log="${log}Error: 网络错误，退出码: ${reload_exit_code}\n\t"
    sub_end 1
elif [ "${reload_response}" -ne 204 ]; then
    log="${log}Error: 配置重新加载失败，响应码: ${reload_response}\n\t"
    sub_end 1
fi

# 记录最后运行时间
date +%s > "${LAST_RUN_FILE}"

log="${log}配置重新加载完成 ✅\n\t"
sub_end 0
