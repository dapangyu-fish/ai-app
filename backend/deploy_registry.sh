#!/bin/bash
# Registry 服务快速部署脚本
# 在服务器上执行此脚本

set -e

echo "=========================================="
echo "Registry 服务部署脚本"
echo "=========================================="

# 配置
PROJECT_DIR="/root/ai-app"
REGISTRY_PORT=3254
LOG_DIR="$PROJECT_DIR/logs"

# 检查目录
if [ ! -d "$PROJECT_DIR" ]; then
    echo "错误: 项目目录不存在: $PROJECT_DIR"
    exit 1
fi

cd "$PROJECT_DIR"

# 创建日志目录
mkdir -p "$LOG_DIR"

# 步骤 1: 初始化索引文件
echo ""
echo "步骤 1: 初始化索引文件..."
python3 backend/registry_init.py

if [ $? -ne 0 ]; then
    echo "错误: 索引初始化失败"
    exit 1
fi

echo "✓ 索引文件初始化成功"

# 步骤 2: 检查端口占用
echo ""
echo "步骤 2: 检查端口 $REGISTRY_PORT..."
if lsof -Pi :$REGISTRY_PORT -sTCP:LISTEN -t >/dev/null ; then
    echo "警告: 端口 $REGISTRY_PORT 已被占用"
    read -p "是否停止现有进程? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PID=$(lsof -Pi :$REGISTRY_PORT -sTCP:LISTEN -t)
        kill -9 $PID
        echo "✓ 已停止进程 $PID"
    else
        echo "取消部署"
        exit 1
    fi
fi

# 步骤 3: 启动服务
echo ""
echo "步骤 3: 启动 Registry 服务..."
nohup python3 backend/registry_server.py > "$LOG_DIR/registry.log" 2>&1 &
REGISTRY_PID=$!

echo "✓ Registry 服务已启动 (PID: $REGISTRY_PID)"

# 等待服务启动
sleep 2

# 步骤 4: 健康检查
echo ""
echo "步骤 4: 健康检查..."
HEALTH_CHECK=$(curl -s http://localhost:$REGISTRY_PORT/health)

if [ $? -eq 0 ]; then
    echo "✓ 服务健康检查通过"
    echo "$HEALTH_CHECK" | python3 -m json.tool
else
    echo "✗ 服务健康检查失败"
    echo "查看日志: tail -f $LOG_DIR/registry.log"
    exit 1
fi

# 步骤 5: 测试依赖解析
echo ""
echo "步骤 5: 测试依赖解析..."
RESOLVE_TEST=$(curl -s "http://localhost:$REGISTRY_PORT/resolve?name=common-ui&version=^1.0.0")

if [ $? -eq 0 ]; then
    echo "✓ 依赖解析测试通过"
    echo "$RESOLVE_TEST" | python3 -m json.tool
else
    echo "✗ 依赖解析测试失败"
fi

# 完成
echo ""
echo "=========================================="
echo "部署完成！"
echo "=========================================="
echo ""
echo "服务信息:"
echo "  - PID: $REGISTRY_PID"
echo "  - 端口: $REGISTRY_PORT"
echo "  - 日志: $LOG_DIR/registry.log"
echo ""
echo "下一步:"
echo "  1. 配置 Nginx 反向代理 (myapp-registry.dapangyu.work → 127.0.0.1:$REGISTRY_PORT)"
echo "  2. 测试远程访问: curl https://myapp-registry.dapangyu.work/health"
echo "  3. 查看日志: tail -f $LOG_DIR/registry.log"
echo ""
echo "管理命令:"
echo "  - 查看进程: ps aux | grep registry_server"
echo "  - 停止服务: kill $REGISTRY_PID"
echo "  - 重启服务: kill $REGISTRY_PID && nohup python3 backend/registry_server.py > $LOG_DIR/registry.log 2>&1 &"
echo ""
