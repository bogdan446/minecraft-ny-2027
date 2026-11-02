#!/usr/bin/env bash
set -e

# 0. Окружение
export PATH="$HOME/.local/bin:$PATH"

CONTAINER_NAME="mc-ny2027-fabric"
SRC_SQLITE="/data/world/data/DistantHorizons.sqlite"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${SCRIPT_DIR}"
DEST_FILE="${DEST_DIR}/DistantHorizons.sqlite"
REPO_HTTPS="https://github.com/bogdan446/minecraft-ny-2027.git"
REPO_SSH="git@github.com:bogdan446/minecraft-ny-2027.git"

# Подгрузка локального .env при наличии
if [ -f "${DEST_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    source "${DEST_DIR}/.env"
fi

echo "=== Экспорт Distant Horizons SQLite, обновление DHSync и отправка в GitHub ==="

# 1. Проверяем, запущен ли контейнер
if ! docker ps --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
    echo "[!] Ошибка: Контейнер $CONTAINER_NAME не запущен!"
    exit 1
fi

# 2. Вызываем save-all через RCON
echo "[*] Сохранение состояния мира (save-all)..."
docker exec "$CONTAINER_NAME" rcon-cli save-all flush 2>/dev/null || docker exec "$CONTAINER_NAME" rcon-cli save-all 2>/dev/null || true

# 3. Автоматическое обновление метаданных DHSync на сервере (размер, SHA-256, версия, reload)
echo "[*] Автоматическое обновление конфигурации DHSync на сервере..."
UPDATE_CMD=("python3" "/data/scripts/update_dh_map.py" "--desc" "Карта дальнего горизонта (3000 блоков)")

GITHUB_LFS_URL="https://media.githubusercontent.com/media/bogdan446/minecraft-ny-2027/main/DistantHorizons.sqlite"

# GitHub LFS является основным высокоскоростным источником (прямой поток байтов без капч)
UPDATE_CMD+=("--primary" "$GITHUB_LFS_URL")

if [ -n "${GDRIVE_FILE_URL:-}" ]; then
    UPDATE_CMD+=("--backup" "$GDRIVE_FILE_URL")
fi

docker exec "$CONTAINER_NAME" "${UPDATE_CMD[@]}"

# 4. Копируем файл из контейнера в рабочую директорию
echo "[*] Копирование базы чанков в: $DEST_DIR"
docker cp "${CONTAINER_NAME}:${SRC_SQLITE}" "${DEST_FILE}"

# 5. Проверяем результат копирования
if [ -f "$DEST_FILE" ]; then
    FILE_SIZE=$(ls -lh "$DEST_FILE" | awk '{print $5}')
    echo "[✔] Успешно! Файл скопирован: $DEST_FILE ($FILE_SIZE)"
else
    echo "[!] Ошибка: Файл не был скопирован."
    exit 1
fi

# 6. Проверка Git LFS
if ! command -v git-lfs &>/dev/null; then
    if [ -x "$HOME/.local/bin/git-lfs" ]; then
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo "[!] Ошибка: git-lfs не найден."
        exit 1
    fi
fi

# 7. Инициализация Git и Git LFS в рабочей директории
cd "$DEST_DIR"

if [ ! -d ".git" ]; then
    echo "[*] Инициализация Git-репозитория в $DEST_DIR..."
    git init -b main
    git remote add origin "$REPO_HTTPS"
else
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || true)
    if [ -z "$CURRENT_REMOTE" ]; then
        git remote add origin "$REPO_HTTPS"
    fi
fi

if [ -z "$(git config user.name)" ]; then
    git config user.name "bogdan446"
fi
if [ -z "$(git config user.email)" ]; then
    git config user.email "bogdan446@users.noreply.github.com"
fi

if [ ! -f .gitignore ]; then
    cat << 'GITOID' > .gitignore
.env
*.tmp
GITOID
fi

echo "[*] Настройка отслеживания базы через Git LFS..."
git lfs install --local
git lfs track "DistantHorizons.sqlite"

git add .gitignore .gitattributes copy_dh_map.sh
git add "DistantHorizons.sqlite"

if git diff --staged --quiet; then
    echo "[ℹ] Изменений в файле DistantHorizons.sqlite не зафиксировано."
else
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[*] Фиксация изменений в коммите..."
    git commit -m "chore: update DistantHorizons.sqlite cache [${TIMESTAMP}]"
fi

# 8. Отправка в GitHub
echo "[*] Подготовка к отправке изменений в GitHub..."
PUSH_TARGET="origin"

if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "[*] Используется GITHUB_TOKEN для HTTPS авторизации..."
    PUSH_TARGET="https://${GITHUB_TOKEN}@github.com/bogdan446/minecraft-ny-2027.git"
elif ssh -T -o BatchMode=yes -o ConnectTimeout=3 git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "[*] Обнаружена активная авторизация по SSH. Отправка через git@github.com..."
    git remote set-url origin "$REPO_SSH"
    PUSH_TARGET="origin"
fi

echo "[*] Выполняется git push..."
if git push -u "$PUSH_TARGET" main; then
    echo ""
    echo "[✔] Успешно! Файл отправлен в репозиторий: https://github.com/bogdan446/minecraft-ny-2027"
    echo "[✔] Все метаданные DHSync обновлены и сервер перезагружен!"
else
    PUSH_STATUS=$?
    echo ""
    echo "[!] Ошибка: Не удалось выполнить git push (код $PUSH_STATUS)."
    echo "[*] Способы быстрой авторизации:"
    echo "    Вариант 1 (SSH-ключ - рекомендуется):"
    echo "      Добавьте открытый ключ сервера в GitHub -> Settings -> SSH Keys:"
    echo "      $(cat ~/.ssh/id_github.pub 2>/dev/null || true)"
    echo ""
    echo "    Вариант 2 (GitHub Personal Access Token):"
    echo "      Запишите в ${DEST_DIR}/.env строку: GITHUB_TOKEN=ghp_ваш_токен"
    exit $PUSH_STATUS
fi
