"""gunicorn 配置 —— user-center 是低流量 admin 工具，sync worker 够用"""

bind = "127.0.0.1:8089"
workers = 2  # admin 工具，2 个就够，余量也防一个 worker 卡住时另一个还能服务
worker_class = "sync"
threads = 1
timeout = 30
keepalive = 5
preload_app = True

accesslog = "/var/log/user-center/access.log"
errorlog = "/var/log/user-center/error.log"
loglevel = "info"

# 防慢速攻击 / 误用
limit_request_line = 4094
limit_request_fields = 100
