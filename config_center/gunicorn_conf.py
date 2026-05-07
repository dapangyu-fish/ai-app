"""gunicorn 配置 —— 高并发 + I/O bound 场景。

- gevent worker：单进程也能撑数千并发，适合 mtime stat + 偶发 SQLite 读这种 I/O bound 场景
- workers=4：8 核机器留一半给现有服务（ai-app/registry/minio 等）
- worker_connections=1000：单 worker 上限并发
- preload_app=True：在 fork 前 import app（共享内存、少了 N 次 init_db），但要小心
  fork 后的 SQLite 连接复用；本服务每次请求开新连接，所以安全
"""

bind = "127.0.0.1:8088"
workers = 4
worker_class = "gevent"
worker_connections = 1000
timeout = 30
graceful_timeout = 30
keepalive = 5
preload_app = True

# supervisor 已经接管 stdout/stderr 落盘，gunicorn 不必重复写文件
accesslog = "-"
errorlog = "-"
access_log_format = '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(D)sus'
