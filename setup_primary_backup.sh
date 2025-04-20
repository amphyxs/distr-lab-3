#!/bin/bash

# Конфигурация
PRIMARY_HOST="pg131"
PRIMARY_USER="postgres0"
STANDBY_HOST="pg137"
STANDBY_USER="postgres0"
BACKUP_DIR="/var/db/postgres0/backups"
WAL_ARCHIVE_DIR="/var/db/postgres0/wal_archive"
RETENTION_PRIMARY="7"  # дней
RETENTION_STANDBY="28" # дней

# Создание необходимых директорий
mkdir -p $BACKUP_DIR
mkdir -p $WAL_ARCHIVE_DIR
chown -R postgres:postgres $BACKUP_DIR
chown -R postgres:postgres $WAL_ARCHIVE_DIR

# Настройка PostgreSQL для архивирования WAL
cat << EOF | tee -a /var/db/postgres0/ygh351/postgresql.conf
# Архивирование WAL
wal_level = replica
archive_mode = on
archive_command = 'scp %p $STANDBY_USER@$STANDBY_HOST:$WAL_ARCHIVE_DIR/%f'
max_wal_senders = 10
wal_keep_segments = 32
EOF

# Создание скрипта резервного копирования
cat << 'EOF' | tee /var/db/postgres0/perform_backup.sh
#!/bin/bash

BACKUP_DIR="/var/db/postgres0/backups"
WAL_ARCHIVE_DIR="/var/db/postgres0/wal_archive"
STANDBY_HOST="pg137"
STANDBY_USER="postgres0"
RETENTION_PRIMARY="7"
RETENTION_STANDBY="28"

# Создание резервной копии
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="base_backup_$TIMESTAMP"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

# Выполнение полного резервного копирования
pg_basebackup -D $BACKUP_PATH -Fp -Xs -P # TODO: не может подключиться к БД

# Сжатие резервной копии
tar -czf $BACKUP_PATH.tar.gz $BACKUP_PATH
rm -rf $BACKUP_PATH

# Копирование на резервный узел
scp $BACKUP_PATH.tar.gz $STANDBY_USER@$STANDBY_HOST:$BACKUP_DIR/

# Очистка старых резервных копий на основном узле
find $BACKUP_DIR -name "base_backup_*.tar.gz" -mtime +$RETENTION_PRIMARY -delete
find $WAL_ARCHIVE_DIR -name "*.history" -mtime +$RETENTION_PRIMARY -delete
find $WAL_ARCHIVE_DIR -name "*.backup" -mtime +$RETENTION_PRIMARY -delete
EOF

# Установка прав на выполнение скрипта резервного копирования
chmod +x /var/db/postgres0/perform_backup.sh

# Добавление задания в cron для еженедельного резервного копирования
(crontab -l 2>/dev/null; echo "0 0 * * 0 /var/db/postgres0/perform_backup.sh") | crontab -

# Перезапуск PostgreSQL для применения изменений
pg_ctl -D /var/db/postgres0/ygh35 restart

echo "Настройка резервного копирования на основном узле завершена!" 