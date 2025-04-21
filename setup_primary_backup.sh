#!/bin/bash

# Конфигурация
BACKUP_DIR="/var/db/postgres0/pg_backup"
WAL_ARCHIVE_DIR="/var/db/postgres0/wal_archive"
REMOTE_HOST="postgres0@pg137"
STANDBY_HOST="postgres0@pg131"
REMOTE_BACKUP_DIR="/var/db/postgres0/pg_backup"
REMOTE_WAL_ARCHIVE_DIR="/var/db/postgres0/wal_archive"
DAYS_TO_KEEP=7  # На основном узле храним 1 неделю
REMOTE_DAYS_TO_KEEP=28  # На резервном узле храним 4 недели
DB_NAME="dryblackfood"
DB_PORT="9833"
DB_USER="postgres0"
DUMP_FILE="/var/db/postgres0/backup_dump.sql"

# Создание резервной копии
DATE=$(date +"%Y%m%d%H%M")
BACKUP_NAME="backup_$DATE"

export BACKUP_DIR WAL_ARCHIVE_DIR REMOTE_HOST STANDBY_HOST REMOTE_BACKUP_DIR \
REMOTE_WAL_ARCHIVE_DIR  WAL_DIR DAYS_TO_KEEP REMOTE_DAYS_TO_KEEP DATE BACKUP_NAME

# Создание необходимых директорий, если их нет
mkdir -p $BACKUP_DIR
mkdir -p $WAL_ARCHIVE_DIR

chown -R postgres0:postgres $BACKUP_DIR
chown -R postgres0:postgres $WAL_ARCHIVE_DIR

# Настройка PostgreSQL для архивирования WAL
cat << EOF | tee -a /var/db/postgres0/ygh351/postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'scp %p $STANDBY_HOST:$WAL_ARCHIVE_DIR/%f'
archive_timeout = 60
EOF

# Попытка перезапуска PostgreSQL: если сервер не запущен — просто стартуем
if pg_ctl -D /var/db/postgres0/ygh351 status > /dev/null 2>&1; then
    echo "PostgreSQL уже запущен, перезапускаем..."
    pg_ctl -D /var/db/postgres0/ygh351 restart
else
    echo "PostgreSQL не запущен, запускаем..."
    pg_ctl -D /var/db/postgres0/ygh351 start
fi

echo "Выполнение полного резервного копирования с помощью pg_basebackup"
pg_basebackup -D $BACKUP_DIR/$BACKUP_NAME -Ft -P -U postgres0 -p 9833

echo "Создание скрипта для бэкапов и cron-джобы по его запуску"
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
pg_basebackup -D $BACKUP_DIR/$BACKUP_NAME -Ft -P -U postgres0 -p 9833

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

chmod +x /var/db/postgres0/perform_backup.sh
(crontab -l 2>/dev/null; echo "0 0 * * 0 /var/db/postgres0/perform_backup.sh") | crontab -

echo "Отправка резервной копии на резервный хост через SCP"
scp $BACKUP_DIR/$BACKUP_NAME/* $REMOTE_HOST:$REMOTE_BACKUP_DIR/

echo "Отправка WAL архива на резервный хост через SCP"
scp $WAL_ARCHIVE_DIR/* $STANDBY_HOST:$REMOTE_WAL_ARCHIVE_DIR/

echo "Начинаем процесс восстановления на резервной узле (ЭТАП 2)"
ssh $REMOTE_HOST

export BACKUP_DIR="/var/db/postgres0/pg_backup"
export WAL_ARCHIVE_DIR="/var/db/postgres0/wal_archive"
export STANDBY_DB_DIR="/var/db/postgres0/ygh351"  
export TABSPACE_BWH48="/var/db/postgres0/bwh48"
export TABSPACE_TDJ86="/var/db/postgres0/tdj86" 
export TABSPACE_IDX47="/var/db/postgres0/idx47" 
export NEW_TABSPACE_BWH48="/var/db/postgres0/newForBhw"

mkdir -p $BACKUP_DIR
mkdir -p $WAL_ARCHIVE_DIR

chown -R postgres0:postgres $BACKUP_DIR
chown -R postgres0:postgres $WAL_ARCHIVE_DIR

if pg_ctl -D $STANDBY_DB_DIR status > /dev/null 2>&1; then
    echo "PostgreSQL работает, останавливаем..."
    pg_ctl -D $STANDBY_DB_DIR stop
else
    echo "PostgreSQL не запущен, продолжаем..."
fi

echo "Очищаем директорию данных..."
rm -rf $STANDBY_DB_DIR/*

echo "Восстанавливаем данные из бэкапа..."
tar -xf $BACKUP_DIR/base.tar -C $STANDBY_DB_DIR

echo "Восстанавливаем WAL архивы..."
tar -xf $BACKUP_DIR/pg_wal.tar -C $STANDBY_DB_DIR/pg_wal

echo "Начинаем доставать табличные пространства"
mkdir -p $TABSPACE_BWH48
mkdir -p $TABSPACE_TDJ86
mkdir -p $TABSPACE_IDX47


tar -xvf $BACKUP_DIR/16387.tar -C $TABSPACE_BWH48
tar -xvf $BACKUP_DIR/16388.tar -C $TABSPACE_IDX47
tar -xvf $BACKUP_DIR/16389.tar -C $TABSPACE_TDJ86

echo "Удаление старых символьных ссылок и создание новых"
rm -f $STANDBY_DB_DIR/pg_tblspc/16387
rm -f $STANDBY_DB_DIR/pg_tblspc/16388
rm -f $STANDBY_DB_DIR/pg_tblspc/16389

ln -s $TABSPACE_BWH48 $STANDBY_DB_DIR/pg_tblspc/16387
ln -s $TABSPACE_IDX47 $STANDBY_DB_DIR/pg_tblspc/16388
ln -s $TABSPACE_TDJ86 $STANDBY_DB_DIR/pg_tblspc/16389


echo "Запуск PostgreSQL на резервной ноде..."
cat << EOF | tee -a $STANDBY_DB_DIR/postgresql.conf
restore_command = 'scp /var/db/postgres0/wal_archive/%f %p'
EOF
touch $STANDBY_DB_DIR/recovery.signal
pg_ctl -D $STANDBY_DB_DIR start

echo "Подключаемся к базе данных и выводим данные..."
psql -p 9833 -U postgres0 -d dryblackfood 
\dt

echo "Этап 3(эмитация сбоя базы данных,связанного с потерей какого-то из табличных пространств)"
rm -rf /var/db/postgres0/bwh48
echo "Смотрим что нету доступа"
psql -p 9833 -U postgres0 -d dryblackfood
SELECT * FROM data_bwh48;
mkdir -p newForBhw
rm -f $STANDBY_DB_DIR/pg_tblspc/16387
echo "Распакуем в новую папку"
tar -xvf $BACKUP_DIR/16387.tar -C $NEW_TABSPACE_BWH48
echo "Перепривяжем в новую папку"
rm -f $STANDBY_DB_DIR/pg_tblspc/16387
ln -s $NEW_TABSPACE_BWH48 $STANDBY_DB_DIR/pg_tblspc/16387
echo "Смотрим появились ли данные"
psql -p 9833 -U postgres0 -d dryblackfood
SELECT * FROM data_bwh48;

DUMP_FILE="/var/db/postgres0/backup_dump.sql"

echo "Этап 4(логическое повреждение данных)"
echo "Начинаем тестирование восстановления данных"

echo "Создаем тестовую таблицу..."
psql -p 9833 -U postgres0 -d postgres << EOF
    CREATE TABLE IF NOT EXISTS test_table (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100),
        description TEXT
    );
EOF

echo "Добавляем тестовые данные в таблицу..."
psql -p 9833 -U postgres0 -d postgres << EOF
    INSERT INTO test_table (name, description) VALUES 
    ('Тестовый Продукт 1', 'Тестовое Описание 1'),
    ('Тестовый Продукт 2', 'Тестовое Описание 2'),
    ('Тестовый Продукт 3', 'Тестовое Описание 3');
EOF

echo "Текущее состояние таблицы после добавления данных:"
psql -p 9833 -U postgres0 -d postgres -c "SELECT * FROM test_table;"

echo "Создаем резервную копию на резервном узле..."
ssh $STANDBY_HOST "pg_dump -p 9833 -U postgres0 -d postgres > $DUMP_FILE"

echo "Имитируем повреждение данных..."
psql -p 9833 -U postgres0 -d postgres << EOF
    UPDATE test_table SET id = id + 10000;
    UPDATE test_table SET name = 'Поврежденные данные ' || id;
EOF

echo "Состояние таблицы после повреждения данных:"
psql -p 9833 -U postgres0 -d postgres -c "SELECT * FROM test_table;"

echo "Восстанавливаем данные из резервной копии..."
scp $STANDBY_HOST:$DUMP_FILE $DUMP_FILE
psql -p 9833 -U postgres0 -d postgres << EOF
    DROP TABLE IF EXISTS test_table;
    \i $DUMP_FILE
EOF

echo "Финальное состояние таблицы после восстановления:"
psql -p 9833 -U postgres0 -d postgres -c "SELECT * FROM test_table;"

echo "Тестирование восстановления данных завершено"