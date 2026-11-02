#!/usr/bin/env bash
set -e

# 0. Окружение: гарантируем доступность git-lfs и bin в PATH
export PATH="$HOME/.local/bin:$PATH"

# Настройки контейнера и путей
CONTAINER_NAME="mc-ny2027-fabric"
SRC_SQLITE="/data/world/data/DistantHorizons.sqlite"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${SCRIPT_DIR}"
DEST_FILE="${DEST_DIR}/DistantHorizons.sqlite"
REPO_URL="https://github.com/bogdan446/minecraft-ny-2027.git"

# Подгрузка локального .env при наличии (для GITHUB_TOKEN)
if [ -f "${DEST_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    source "${DEST_DIR}/.env"
fi

echo "=== Экспорт Distant Horizons SQLite и отправка в GitHub ==="

# 1. Проверяем, запущен ли контейнер
if ! docker ps --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
    echo "[!] Ошибка: Контейнер $CONTAINER_NAME не запущен!"
    exit 1
fi

# 2. Вызываем save-all через RCON, чтобы сбросить свежие чанки из памяти на диск
echo "[*] Сохранение состояния мира (save-all)..."
docker exec "$CONTAINER_NAME" rcon-cli save-all flush 2>/dev/null || docker exec "$CONTAINER_NAME" rcon-cli save-all 2>/dev/null || true

# 3. Копируем файл из контейнера в рабочую директорию
echo "[*] Копирование базы чанков в: $DEST_DIR"
docker cp "${CONTAINER_NAME}:${SRC_SQLITE}" "${DEST_FILE}"

# 4. Проверяем результат копирования
if [ -f "$DEST_FILE" ]; then
    FILE_SIZE=$(ls -lh "$DEST_FILE" | awk '{print $5}')
    echo "[✔] Успешно! Файл скопирован: $DEST_FILE ($FILE_SIZE)"
else
    echo "[!] Ошибка: Файл не был скопирован."
    exit 1
fi

# 5. Проверка Git LFS (для файлов >100 МБ)
if ! command -v git-lfs &>/dev/null; then
    echo "[!] Ошибка: git-lfs не найден. Файлы >100 МБ отклоняются GitHub без LFS."
    echo "[*] Установите git-lfs в ~/.local/bin или через apt."
    exit 1
fi

# 6. Инициализация Git и Git LFS в рабочей директории
cd "$DEST_DIR"

if [ ! -d ".git" ]; then
    echo "[*] Инициализация Git-репозитория в $DEST_DIR..."
    git init -b main
    git remote add origin "$REPO_URL"
else
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || true)
    if [ -z "$CURRENT_REMOTE" ]; then
        git remote add origin "$REPO_URL"
    fi
fi

# Обеспечиваем наличие базовых настроек коммитера
if [ -z "$(git config user.name)" ]; then
    git config user.name "bogdan446"
fi
if [ -z "$(git config user.email)" ]; then
    git config user.email "bogdan446@users.noreply.github.com"
fi

# Защита от случайной отправки секретов (.env)
if [ ! -f .gitignore ]; then
    cat << 'GITOID' > .gitignore
.env
*.tmp
GITOID
fi

# Настройка Git LFS для тяжелой SQLite базы
echo "[*] Настройка отслеживания базы через Git LFS..."
git lfs install --local
git lfs track "DistantHorizons.sqlite"

# 7. Индексация и создание коммита
git add .gitignore .gitattributes copy_dh_map.sh
git add "DistantHorizons.sqlite"

if git diff --staged --quiet; then
    echo "[ℹ] Изменений в файле DistantHorizons.sqlite не зафиксировано, коммит пропущен."
else
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[*] Фиксация изменений в коммите..."
    git commit -m "chore: update DistantHorizons.sqlite cache [${TIMESTAMP}]"
fi

# 8. Отправка в удаленный репозиторий GitHub
echo "[*] Отправка изменений в GitHub ($REPO_URL)..."

# Если передан GITHUB_TOKEN, используем его для авторизации
PUSH_TARGET="origin"
if [ -n "${GITHUB_TOKEN:-}" ]; then
    PUSH_TARGET="https://${GITHUB_TOKEN}@github.com/bogdan446/minecraft-ny-2027.git"
fi

if git push -u "$PUSH_TARGET" main; then
    echo "[✔] Успешно! Файл отправлен в репозиторий: $REPO_URL"
else
    PUSH_STATUS=$?
    echo ""
    echo "[!] Ошибка: Не удалось выполнить git push (код $PUSH_STATUS)."
    echo "[*] Подсказка по авторизации:"
    echo "    1. Если у вас есть GitHub Personal Access Token (PAT):"
    echo "       export GITHUB_TOKEN=ghp_ваш_токен"
    echo "       или запишите его в файл: ${DEST_DIR}/.env (строка: GITHUB_TOKEN=ghp_...)"
    echo "    2. Либо настройте SSH-ключ с доступом к github.com и смените URL на git@github.com:..."
    exit $PUSH_STATUS
fi
