#!/bin/bash

apt install -y nginx
touch /etc/nginx/sites-available/mainsail
touch /etc/nginx/conf.d/upstreams.conf
touch /etc/nginx/conf.d/common_vars.conf

cat <<EOF > /etc/nginx/conf.d/upstreams.conf
upstream apiserver {
    ip_hash;
    server 127.0.0.1:7125;
}

upstream mjpgstreamer1 {
    ip_hash;
    server 127.0.0.1:8080;
}

upstream mjpgstreamer2 {
    ip_hash;
    server 127.0.0.1:8081;
}

upstream mjpgstreamer3 {
    ip_hash;
    server 127.0.0.1:8082;
}

upstream mjpgstreamer4 {
    ip_hash;
    server 127.0.0.1:8083;
}
EOF

cat << EOF > /etc/nginx/conf.d/common_vars.conf
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}
EOF

cat <<EOF > /etc/nginx/sites-available/mainsail
server {
    listen 80 default_server;

    access_log /var/log/nginx/mainsail-access.log;
    error_log /var/log/nginx/mainsail-error.log;

    # disable this section on smaller hardware like a pi zero
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_proxied expired no-cache no-store private auth;
    gzip_comp_level 4;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/x-javascript application/json application/xml;

    # web_path from mainsail static files
    root /home/debian/mainsail;

    index index.html;
    server_name _;

    # disable max upload size checks
    client_max_body_size 0;

    # disable proxy request buffering
    proxy_request_buffering off;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location = /index.html {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }

    location /websocket {
        proxy_pass http://apiserver/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    location ~ ^/(printer|api|access|machine|server)/ {
        proxy_pass http://apiserver\$request_uri;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Scheme \$scheme;
    }

    location /webcam/ {
        proxy_pass http://mjpgstreamer1/;
    }

    location /webcam2/ {
        proxy_pass http://mjpgstreamer2/;
    }

    location /webcam3/ {
        proxy_pass http://mjpgstreamer3/;
    }

    location /webcam4/ {
        proxy_pass http://mjpgstreamer4/;
    }
}
EOF


mkdir -p /home/debian/mainsail
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/
systemctl restart nginx

cd /home/debian/mainsail
wget -q -O mainsail.zip https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip && unzip mainsail.zip && rm mainsail.zip

systemctl stop octoprint
systemctl disable octoprint
systemctl stop nftables
systemctl disable nftables
