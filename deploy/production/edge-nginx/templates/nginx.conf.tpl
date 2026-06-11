user nginx;
worker_processes auto;

error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
  worker_connections 4096;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
  access_log /var/log/nginx/access.log main;

  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;
  server_tokens off;

  client_max_body_size {{CLIENT_MAX_BODY_SIZE}};
  proxy_read_timeout {{PROXY_READ_TIMEOUT}};
  proxy_send_timeout {{PROXY_SEND_TIMEOUT}};
  proxy_connect_timeout {{PROXY_CONNECT_TIMEOUT}};
  resolver 127.0.0.11 valid=10s ipv6=off;
  resolver_timeout 5s;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  include /etc/nginx/conf.d/*.conf;
}
