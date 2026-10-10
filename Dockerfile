FROM metacubex/mihomo:v1.19.32

RUN apk add --no-cache jq curl busybox-extras

# 安装 yq，用于 overlay.yaml 合并（不存在则跳过，不影响原有多订阅流程）
ARG TARGETARCH
ARG TARGETVARIANT
RUN case "${TARGETARCH}${TARGETVARIANT}" in \
        "arm64") YQ_BIN="yq_linux_arm64" ;; \
        "armv7") YQ_BIN="yq_linux_arm" ;; \
        "386") YQ_BIN="yq_linux_386" ;; \
        "amd64"|*) YQ_BIN="yq_linux_amd64" ;; \
    esac && \
    wget -O /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.44.3/${YQ_BIN}" && \
    chmod +x /usr/local/bin/yq

# 安装 metacubexd Web 面板（存到初始化目录，运行时由 init.sh 复制）
# v1.273.1 (2026-09-10)：修复桌面端原生 TUN helper 启动与恢复
RUN wget -O /tmp/metacubexd.tgz https://github.com/MetaCubeX/metacubexd/releases/download/v1.273.1/compressed-dist.tgz && \
    tar -tzf /tmp/metacubexd.tgz > /dev/null 2>&1 || { echo "metacubexd download corrupted"; exit 1; } && \
    mkdir -p /usr/share/mihomo-init/ui && \
    tar -xzf /tmp/metacubexd.tgz -C /usr/share/mihomo-init/ui && \
    rm -rf /tmp/metacubexd.tgz

# 安装 subconverter（MetaCubeX C++ 版 v0.9.2，多架构支持）
# 上游 3.0.0 已从 asdlokj1qpi233 fork 切回 MetaCubeX 官方版，此处跟进
RUN case "${TARGETARCH}${TARGETVARIANT}" in \
        "arm64") \
            SUBCONV_FILE="subconverter_aarch64.tar.gz" ;; \
        "armv7") \
            SUBCONV_FILE="subconverter_armv7.tar.gz" ;; \
        "386") \
            SUBCONV_FILE="subconverter_linux32.tar.gz" ;; \
        "amd64") \
            SUBCONV_FILE="subconverter_linux64.tar.gz" ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}${TARGETVARIANT}"; exit 1 ;; \
    esac && \
    wget -O /tmp/subconverter.tar.gz https://github.com/MetaCubeX/subconverter/releases/download/v0.9.2/${SUBCONV_FILE} && \
    tar -tzf /tmp/subconverter.tar.gz > /dev/null 2>&1 || { echo "subconverter download corrupted"; exit 1; } && \
    tar -xzf /tmp/subconverter.tar.gz -C / && \
    rm -rf /tmp/subconverter.tar.gz

# subconverter 仅本机使用，改监听 127.0.0.1（host 网络下 0.0.0.0 等于局域网开放的
# 免鉴权抓取服务）。已实测它会读取可执行文件同目录的 pref.ini，
# init.sh 从任意工作目录启动均生效
RUN printf '[common]\nlisten=127.0.0.1\nport=25500\n' > /subconverter/pref.ini

# 初始 mihomo 配置（存到初始化目录，运行时由 init.sh 复制）
RUN echo 'mixed-port: 7890' > /usr/share/mihomo-init/config.yaml && \
    echo 'external-ui: /root/.config/mihomo/ui' >> /usr/share/mihomo-init/config.yaml && \
    echo 'allow-lan: true' >> /usr/share/mihomo-init/config.yaml && \
    echo 'external-controller: 0.0.0.0:9090' >> /usr/share/mihomo-init/config.yaml

# 预下载 GeoIP/GeoSite 数据库，避免启动时在国内直连 GitHub 超时
# busybox wget 不支持 --retry-connrefused，用 shell 循环做重试
RUN for f in geoip.metadb geosite.dat; do \
        ok=false; \
        for i in 1 2 3 4 5; do \
            wget -q -T 60 -O "/usr/share/mihomo-init/${f}" \
                "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${f}" && \
            [ "$(wc -c < "/usr/share/mihomo-init/${f}")" -gt 102400 ] && ok=true && break; \
            echo "retry ${i}/5: ${f}"; \
            sleep 2; \
        done; \
        $ok || { echo "failed to download ${f}"; exit 1; }; \
    done

# 安装管理页面
RUN mkdir -p /usr/share/mihomo-mgr/cgi-bin
COPY mgr/index.html /usr/share/mihomo-mgr/index.html
COPY mgr/cgi-bin/api /usr/share/mihomo-mgr/cgi-bin/api
RUN chmod +x /usr/share/mihomo-mgr/cgi-bin/api

# 安装启动脚本、订阅脚本和健康检查
COPY init.sh /init.sh
COPY sub.sh /etc/periodic/15min/sub.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /init.sh /etc/periodic/15min/sub.sh /usr/local/bin/healthcheck.sh

# SECRET 为空 = 面板无密码（保持旧行为）；设置后 mihomo API 需要鉴权，
# sub.sh 热重载与 HEALTHCHECK 会自动读取数据卷中的 .secret
ENV sub_url="" \
    SECRET=""

EXPOSE 7890 9090 9091

HEALTHCHECK --interval=120s --timeout=10s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/init.sh"]
