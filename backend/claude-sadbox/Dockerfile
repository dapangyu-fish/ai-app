FROM ubuntu:26.04

# 避免在 apt-get install 时出现交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# 1. 安装所需的基础依赖
RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    build-essential \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# 2. 设置 NVM 的环境变量
ENV NVM_DIR="/root/.nvm"
ENV NODE_VERSION="22.14.0" 

# 3. 安装 NVM，再用 NVM 安装 Node.js (包含了 npm)
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install $NODE_VERSION \
    && nvm alias default $NODE_VERSION \
    && nvm use default

# 把 node 和 npm 加到环境变量 PATH，这样不用执行 nvm.sh 也能直接运行 npm 和 claude
ENV PATH="$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH"

# 4. 用 npm 全局安装 Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# 设置工作目录
WORKDIR /app

# 默认环境变量，允许以 root 权限运行 claude，并禁用不必要的流量
ENV IS_SANDBOX=1
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

CMD ["/bin/bash"]
