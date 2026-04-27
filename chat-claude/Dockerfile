FROM ubuntu:24.04
USER root
WORKDIR /root
ENV DEBIAN_FRONTEND=noninteractive

#=======================
# install apt
#=======================
RUN apt update && apt upgrade -y \
               && apt install -y git git-lfs wget curl tini vim git procps unzip zip jq gcc \
               && apt autoclean -y \
               && apt autoremove -y \
               && rm -rf /var/lib/apt/lists/*

#=======================
# install miniconda
#=======================
RUN mkdir -p /opt/miniconda3 && \
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /opt/miniconda3/miniconda.sh && \
    bash /opt/miniconda3/miniconda.sh -b -u -p /opt/miniconda3 && \
    rm /opt/miniconda3/miniconda.sh && \
    /opt/miniconda3/bin/conda init && . /opt/miniconda3/bin/activate


ENV NVM_DIR=/root/.nvm
ENV NODE_VERSION=22.22.2

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
RUN . "$NVM_DIR/nvm.sh" && \
    nvm install $NODE_VERSION && \
    nvm use $NODE_VERSION && \
    nvm alias default $NODE_VERSION

ENV PATH=$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH
RUN node --version && npm --version && echo "✅ NVM + Node v$NODE_VERSION 安装完成！"

RUN echo "source /opt/miniconda3/bin/activate" >> ~/.bashrc



RUN npm install -g @anthropic-ai/claude-code

