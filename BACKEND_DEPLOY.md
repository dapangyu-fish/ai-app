# 后端部署文档

## 登录服务器

通过 SSH 登录到后端服务器：

```bash
ssh root@app-backend.dapangyu.work
```

（本机已配置免密登录，无需输入密码）

## 代码位置

代码位于服务器的 `/root/ai-app` 目录。

## 更新代码

在本地提交代码后，在服务器上执行以下命令更新最新代码：

```bash
cd /root/ai-app
git pull
```

## 启动后端服务

后端服务使用 Flask，主要文件为 `tools/ai_server.py`。服务器环境使用 miniconda，默认已激活 base 环境。

启动命令：

```bash
cd /root/ai-app
python tools/ai_server.py
```

服务默认运行在端口 5566。

## 服务管理

后端服务已配置 supervisor 进行管理。

### supervisor 配置文件位置
`/etc/supervisor/conf.d/ai-app.conf`

### 常用管理命令

```bash
# 查看服务状态
supervisorctl status

# 启动服务
supervisorctl start ai-app

# 停止服务
supervisorctl stop ai-app

# 重启服务
supervisorctl restart ai-app

# 重新加载配置文件
supervisorctl reread
supervisorctl update

# 查看日志
tail -f /var/log/ai-app/ai-app.log
tail -f /var/log/ai-app/ai-app-error.log
```

### 更新代码后重启服务

```bash
cd /root/ai-app
git pull
supervisorctl restart ai-app
```

### 日志文件位置
- 标准输出日志: `/var/log/ai-app/ai-app.log`
- 错误日志: `/var/log/ai-app/ai-app-error.log`
