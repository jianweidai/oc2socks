# 使用一个轻量级的 Alpine 作为基础镜像
FROM alpine:latest

# 安装 openconnect, curl, ca-certificates, iproute2 等工具
# 使用 apk --no-cache 可以避免缓存，保持镜像小巧
# 添加 bash 是为了更好地兼容可能使用 bash 特性的脚本 (如 start.sh)
RUN apk update && \
    apk add --no-cache \
    openconnect \
    curl \
    ca-certificates \
    iproute2 \
    unzip \
    procps \
    bash \
    python3 \
    py3-pip

# 安装 Flask 后端依赖
RUN pip install --no-cache-dir --break-system-packages flask

# 从 GitHub 下载并安装最新版的 gost
# 注意：gost 的 linux_amd64 版本通常是静态链接的，因此可以在 Alpine (musl) 上运行。
# 如果遇到问题，请检查 gost 的 GitHub Release 页面是否有专门为 musl/Alpine 编译的版本。
ARG GOST_VERSION=2.12.0
RUN curl -L "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz" | tar -xz && \
    mv gost /usr/local/bin/gost && \
    chmod +x /usr/local/bin/gost

# 复制文件与模板
COPY start.sh /start.sh
COPY admin_server.py /admin_server.py
COPY templates/ /templates/

# 创建数据目录用于持久化 Token
RUN mkdir -p /data && chmod +x /start.sh

# 容器启动时执行的命令
CMD ["/start.sh"]