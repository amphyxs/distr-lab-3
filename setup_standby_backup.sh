#!/bin/bash

# Конфигурация
BACKUP_DIR="/var/db/postgres0/backups"
WAL_ARCHIVE_DIR="/var/db/postgres0/wal_archive"
RETENTION_STANDBY="28" # дней

# Создание необходимых директорий
mkdir -p $BACKUP_DIR
mkdir -p $WAL_ARCHIVE_DIR
chown -R postgres:postgres $BACKUP_DIR
chown -R postgres:postgres $WAL_ARCHIVE_DIR

# Создание скрипта очистки
cat << 'EOF' | tee /var/db/postgres0/cleanup_old_backups.sh
#!/bin/bash

BACKUP_DIR="/var/db/postgres0/postgresql/backups"
WAL_ARCHIVE_DIR="/var/db/postgres0/postgresql/wal_archive"
RETENTION_STANDBY="28"

# Очистка старых резервных копий на резервном узле
find $BACKUP_DIR -name "base_backup_*.tar.gz" -mtime +$RETENTION_STANDBY -delete
find $WAL_ARCHIVE_DIR -name "*.history" -mtime +$RETENTION_STANDBY -delete
find $WAL_ARCHIVE_DIR -name "*.backup" -mtime +$RETENTION_STANDBY -delete
EOF

# Установка прав на выполнение скрипта очистки
chmod +x /var/db/postgres0/cleanup_old_backups.sh

# Добавление задания в cron для ежедневной очистки
(crontab -l 2>/dev/null; echo "0 1 * * * /var/db/postgres0/cleanup_old_backups.sh") | crontab -

echo "Настройка резервного копирования на резервном узле завершена!" 