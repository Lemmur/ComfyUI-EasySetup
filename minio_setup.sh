#!/bin/bash

# 1. Установка необходимых пакетов
sudo apt update && sudo apt install rclone fuse3 -y

# 2. Настройка FUSE (разрешаем allow-other)
sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

# 3. Создание конфига rclone
mkdir -p ~/.config/rclone/
cat <<EOF > ~/.config/rclone/rclone.conf
[minio]
type = s3
provider = Minio
access_key_id = MOKJSZMZ4I4Z29GN2D7K
secret_access_key = 6xK898K16LkXcfWB372paODpg10xmL3I7BFhVpPF
endpoint = http://192.168.88.40:9000
EOF

# 4. Очистка папки ComfyUI/models
# Если папка существует и не пуста, переименовываем её в бэкап
MODELS_DIR="/home/ubuntu/ComfyUI/models"
if [ -d "$MODELS_DIR" ]; then
    if [ "$(ls -A $MODELS_DIR)" ]; then
        echo "Папка models не пуста. Создаю бэкап..."
        mv "$MODELS_DIR" "${MODELS_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$MODELS_DIR"
    fi
else
    mkdir -p "$MODELS_DIR"
fi

# 5. Создание системного сервиса
sudo cat <<EOF > /etc/systemd/system/rclone-minio.service
[Unit]
Description=Rclone Mount MinIO for ComfyUI Models
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
ExecStart=/usr/bin/rclone mount minio:comfy-models $MODELS_DIR \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 150G \\
    --vfs-cache-max-age 24h \\
    --vfs-read-chunk-size 64M \\
    --vfs-read-chunk-size-limit 1G \\
    --buffer-size 128M \\
    --allow-other \\
    --vfs-cache-poll-interval 1m \\
    --attr-timeout 10s \\
    --dir-cache-time 1m
ExecStop=/bin/fusermount -u $MODELS_DIR
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 6. Запуск сервиса
sudo systemctl daemon-reload
sudo systemctl enable rclone-minio.service
sudo systemctl restart rclone-minio.service

echo "----------------------------------------"
echo "Готово! Проверяю статус монтирования..."
sleep 2
df -h | grep rclone
