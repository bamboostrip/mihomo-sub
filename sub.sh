#!/bin/sh

# ---------------------------
# 路径与变量
# ---------------------------
CONFIG_DIR="/root/.config/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
GOOD_FILE="${CONFIG_DIR}/config.yaml.good"
OVERLAY_FILE="${CONFIG_DIR}/overlay.yaml"
SECRET_FILE="${CONFIG_DIR}/.secret"
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

# API 密钥：环境变量 > 数据卷持久化文件 > 空（无密码，保持旧行为）
# 由 init.sh 在启动时写入 .secret，此处只做读取，支持容器重启后保持一致
if [ -z "${SECRET}" ] && [ -f "${SECRET_FILE}" ]; then
    SECRET=$(tr -d '[:space:]' < "${SECRET_FILE}" 2>/dev/null)
fi

# YAML 双引号转义（secret 写入配置时用）
yaml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 直连下载：绕开代理（避免经由自身 7890 循环）+ 重试
curl_direct() {
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl -sL --retry 3 --retry-delay 2 --max-time 30 "$@"
}

# 本机请求：同样绕开代理，避免 HEALTHCHECK/热重载被代理劫持
curl_local() {
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl -s "$@"
}

# 回滚上一份可用配置（移植自上游 3.0.0：失败保留上一份可用配置）
restore_good_config() {
    if [ -f "${GOOD_FILE}" ]; then
        cp -f "${GOOD_FILE}" "${CONFIG_FILE}"
        log="${log}已恢复上一份可用配置\n\t"
    fi
}

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
# 别名前缀：将某订阅的节点名 / 策略组名统一改写为 "别名 | 原名"
# 解决同一家多账号节点重名冲突，面板上也能区分流量归属。
# 对 temp_file 原地改写前先做两遍扫描：第一遍建重命名映射，
# 第二遍改写定义与引用（策略组成员、规则策略字段），保证引用一致。
# 无别名时不调用，保持原行为。
# ---------------------------
apply_alias_prefix() {
    file="$1"
    prefix="$2"
    tmp_renamed="${file}.renamed"
    awk -v pre="${prefix}" '
        function esc(s,   t) { t=s; gsub(/\\/, "\\\\", t); gsub(/["]/, "\\\"", t); return t }
        function norm(v,   k) { k=v; gsub(/^["]|["]$/, "", k); gsub(/^ +| +$/, "", k); return k }
        function is_top(key) { return (key ~ /^[A-Za-z][A-Za-z0-9_-]*:[ \t]*$/) }
        NR==FNR {
            if ($0 ~ /^proxies:[ \t]*$/) { sec="proxies"; next }
            if ($0 ~ /^proxy-groups:[ \t]*$/) { sec="groups"; next }
            if (is_top($0)) { sec=""; next }
            if ((sec=="proxies" || sec=="groups") && $0 ~ /^  - name: /) {
                v=$0; sub(/^  - name: /, "", v)
                k=norm(v)
                if (k != "" && !(k in mp)) mp[k]=1
            }
            next
        }
        FNR==1 { sec="" }
        $0 ~ /^proxies:[ \t]*$/ { sec="proxies"; print; next }
        $0 ~ /^proxy-groups:[ \t]*$/ { sec="groups"; print; next }
        $0 ~ /^rules:[ \t]*$/ { sec="rules"; print; next }
        is_top($0) { sec=""; print; next }
        (sec=="proxies" || sec=="groups") && /^  - name: / {
            v=$0; sub(/^  - name: /, "", v)
            k=norm(v)
            printf "  - name: \"%s | %s\"\n", esc(pre), esc(k)
            next
        }
        sec=="groups" && /^[ \t]*- / {
            ind=$0; sub(/-.*$/, "- ", ind)
            ref=$0; sub(/^[ \t]*- +/, "", ref)
            k=norm(ref)
            if (k in mp) printf "%s\"%s | %s\"\n", ind, esc(pre), esc(k)
            else print
            next
        }
        sec=="rules" && /^  - / {
            n=split($0, f, ",")
            idx=n
            key=f[n]; gsub(/^ +| +$/, "", key)
            if (key=="no-resolve" && n>=3) { idx=n-1; key=f[idx]; gsub(/^ +| +$/, "", key) }
            gsub(/^["]|["]$/, "", key)
            if (key in mp) f[idx]="\"" esc(pre) " | " esc(key) "\""
            out=f[1]
            for (i=2;i<=n;i++) out=out "," f[i]
            print out
            next
        }
        { print }
    ' "${file}" "${file}" > "${tmp_renamed}" 2>/dev/null && mv "${tmp_renamed}" "${file}"
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
    # 订阅行格式：纯 URL，或 "别名<TAB>URL"（TAB 不可能出现在 URL 里）
    # 无 TAB 即老格式，保持兼容
    _f1=$(printf '%s' "${line}" | cut -f1)
    _f2=$(printf '%s' "${line}" | cut -f2)
    if [ "${_f2}" = "${line}" ]; then
        SUB_ALIAS=""
        sub_url="${line}"
    else
        SUB_ALIAS=$(printf '%s' "${_f1}" | tr -d '\r\n')
        sub_url="${_f2}"
    fi
    if [ -z "${sub_url}" ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 地址为空，已跳过\n\t"
        continue
    fi
    if [ -n "${SUB_ALIAS}" ]; then
        log_tag=" [${SUB_ALIAS}]"
    else
        log_tag=""
    fi
    raw_file="${TEMP_DIR}/raw_${sub_count}.txt"
    temp_file="${TEMP_DIR}/sub_${sub_count}.yml"

    log="${log}第 ${sub_count} 个订阅${log_tag}获取中...\n\t"

    # curl 直接下载原始订阅，正确设置 User-Agent
    # 绕开代理 + 跟随跳转 + 检查 HTTP 状态码（移植自上游 3.0.0 的健壮下载）
    curl_exit=0
    http_code=$(curl_direct -w "%{http_code}" -H "User-Agent: ${SUB_UA}" -o "${raw_file}" "${sub_url}" 2>/dev/null) || curl_exit=$?

    if [ "${curl_exit}" -ne 0 ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 下载失败，退出码: ${curl_exit}\n\t"
        continue
    fi

    if [ "${http_code:-0}" -ne 200 ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 下载失败，响应码: ${http_code}\n\t"
        continue
    fi

    if [ ! -s "${raw_file}" ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 返回空内容\n\t"
        continue
    fi

    # 判断原始内容格式：如果已经是 clash YAML 则直接使用（允许行首空格）
    if grep -qE '^[[:space:]]*proxies:' "${raw_file}" 2>/dev/null; then
        cp "${raw_file}" "${temp_file}"
        log="${log}订阅 ${sub_count}${log_tag} 已为 Clash 格式\n\t"
    else
        # 非 Clash 格式，通过 subconverter 转换（本机请求同样绕开代理）
        encoded_sub_url=$(jq -rn --arg x "${sub_url}" '$x|@uri' 2>/dev/null)
        encoded_ua=$(jq -rn --arg x "${SUB_UA}" '$x|@uri' 2>/dev/null)
        http_code=$(curl_local --max-time 30 -w "%{http_code}" -o "${temp_file}" "http://127.0.0.1:25500/sub?target=clash&url=${encoded_sub_url}&ua=${encoded_ua}")
        curl_exit=$?

        if [ "${curl_exit}" -ne 0 ]; then
            log="${log}Error: 订阅 ${sub_count}${log_tag} 转换失败，退出码: ${curl_exit}\n\t"
            continue
        elif [ "${http_code:-0}" -ne 200 ]; then
            log="${log}Error: 订阅 ${sub_count}${log_tag} 转换失败，响应码: ${http_code}\n\t"
            continue
        fi
    fi

    if [ ! -s "${temp_file}" ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 处理后为空\n\t"
        continue
    fi

    # 有别名则统一加前缀（节点名/策略组名/引用一起改，保证一致）
    if [ -n "${SUB_ALIAS}" ]; then
        apply_alias_prefix "${temp_file}" "${SUB_ALIAS}"
        log="${log}订阅 ${sub_count}${log_tag}已添加别名前缀\n\t"
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
        log="${log}订阅 ${sub_count}${log_tag} 更新成功\n\t"
    else
        log="${log}订阅 ${sub_count}${log_tag} 无有效节点\n\t"
    fi

done < "${SUB_URLS_FILE}"

if [ "${success_count}" -eq 0 ]; then
    log="${log}Error: 所有订阅均失败，保留现有配置\n\t"
    restore_good_config
    sub_end 1
fi

# ---------------------------
# 构建最终配置文件（printf %s 不解释转义，订阅数据安全）
# secret 为空时写入空字符串 = 无密码（保持旧行为）；设置后面板与 API 需要鉴权
# ---------------------------
# 多订阅合并去重：同名节点只保留第一次出现
# （mihomo 要求 proxies 内 name 唯一，重名会导致重载 400 被拒）
if [ -n "${all_proxies}" ]; then
    proxy_before=$(printf '%s' "${all_proxies}" | grep -cE '^  - name: ' || true)
    all_proxies=$(printf '%s' "${all_proxies}" | awk '
        /^  - name: / {
            nm=$0
            sub(/^  - name: /, "", nm)
            gsub(/^["]|["]$/, "", nm)
            gsub(/^ +| +$/, "", nm)
            if (nm in seen) { skip=1; next }
            seen[nm]=1; skip=0; print; next
        }
        skip { next }
        { print }
    ')
    proxy_after=$(printf '%s' "${all_proxies}" | grep -cE '^  - name: ' || true)
    # $() 会剥掉末尾换行，补回来（否则 proxies 块与下一节粘连）
    all_proxies="${all_proxies}
"
    proxy_dedup=$((proxy_before - proxy_after))
    if [ "${proxy_dedup}" -gt 0 ]; then
        log="${log}已去除 ${proxy_dedup} 个重名节点\n\t"
    fi
fi
SECRET_ESC=$(yaml_escape "${SECRET}")
{
    printf '%s\n' 'mixed-port: 7890'
    printf '%s\n' 'external-ui: /root/.config/mihomo/ui'
    printf '%s\n' 'allow-lan: true'
    printf '%s\n' "secret: \"${SECRET_ESC}\""

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
} > "${CONFIG_FILE}.new"

if [ ! -s "${CONFIG_FILE}.new" ]; then
    log="${log}Error: 配置文件生成失败\n\t"
    restore_good_config
    sub_end 1
fi

# 可选 overlay.yaml 深合并（移植自上游 3.0.0，不存在则跳过，不影响原有多订阅流程）
if [ -f "${OVERLAY_FILE}" ] && [ -s "${OVERLAY_FILE}" ]; then
    if command -v yq > /dev/null 2>&1; then
        if yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            "${CONFIG_FILE}.new" "${OVERLAY_FILE}" > "${CONFIG_FILE}.merged" 2>/dev/null; then
            yq -i '
                .rules = ((.["rules-prepend"] // []) + (.rules // []) + (.["rules-append"] // [])) |
                del(.["rules-prepend"]) | del(.["rules-append"])
            ' "${CONFIG_FILE}.merged" 2>/dev/null
            # 强制受管字段，避免 overlay 覆盖端口、面板与密钥
            yq -i '
                ."mixed-port" = 7890 |
                ."allow-lan" = true |
                ."external-controller" = "0.0.0.0:9090" |
                ."external-ui" = "/root/.config/mihomo/ui"
            ' "${CONFIG_FILE}.merged" 2>/dev/null
            mv "${CONFIG_FILE}.merged" "${CONFIG_FILE}.new"
            log="${log}已合并 overlay.yaml\n\t"
        else
            log="${log}Warning: overlay.yaml 合并失败，沿用转换结果\n\t"
        fi
    else
        log="${log}Warning: 未安装 yq，跳过 overlay.yaml\n\t"
    fi
fi

# secret 由脚本强制写入，不允许 overlay 覆盖
if command -v yq > /dev/null 2>&1; then
    yq -i ".secret = \"${SECRET_ESC}\"" "${CONFIG_FILE}.new" 2>/dev/null || true
fi

mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"

if [ ! -s "${CONFIG_FILE}" ]; then
    log="${log}Error: 配置文件生成失败\n\t"
    restore_good_config
    sub_end 1
fi

log="${log}配置文件生成成功 (${success_count}/${sub_count} 个订阅) ✅\n\t"

# ---------------------------
# 配置重新加载（带 SECRET 鉴权 + 失败回滚，移植自上游 3.0.0）
# ---------------------------
log="${log}配置重新加载...\n\t"
reload_body="${TEMP_DIR}/reload_body.txt"
if [ -n "${SECRET}" ]; then
    reload_response=$(curl_local --max-time 15 -w "%{http_code}" -o "${reload_body}" -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -H "Authorization: Bearer ${SECRET}" -d '{"path":"","payload":""}')
else
    reload_response=$(curl_local --max-time 15 -w "%{http_code}" -o "${reload_body}" -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -d '{"path":"","payload":""}')
fi
reload_exit_code=$?

if [ "${reload_exit_code}" -ne 0 ]; then
    log="${log}Warning: mihomo 服务未启动，跳过热重载（启动后会读取新配置）\n\t"
    cp -f "${CONFIG_FILE}" "${GOOD_FILE}"
elif [ "${reload_response:-0}" -ne 204 ] && [ "${reload_response:-0}" -ne 200 ]; then
    reload_msg=$(head -c 300 "${reload_body}" 2>/dev/null | tr '\n' ' ')
    log="${log}Error: 配置重新加载失败，响应码: ${reload_response} ${reload_msg}，尝试回滚\n\t"
    cp -f "${CONFIG_FILE}" "${CONFIG_FILE}.bad"
    log="${log}失败配置已另存为 config.yaml.bad 供排查\n\t"
    if [ -f "${GOOD_FILE}" ]; then
        cp -f "${GOOD_FILE}" "${CONFIG_FILE}"
        if [ -n "${SECRET}" ]; then
            curl_local --max-time 15 -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -H "Authorization: Bearer ${SECRET}" -d '{"path":"","payload":""}' >/dev/null 2>&1 || true
        else
            curl_local --max-time 15 -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -d '{"path":"","payload":""}' >/dev/null 2>&1 || true
        fi
        log="${log}已回滚上一份可用配置\n\t"
    fi
    sub_end 1
else
    cp -f "${CONFIG_FILE}" "${GOOD_FILE}"
fi

# 记录最后运行时间
date +%s > "${LAST_RUN_FILE}"

log="${log}配置重新加载完成 ✅\n\t"
sub_end 0
