#!/usr/bin/env bash

set -euo pipefail

# Цветной вывод
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Парсинг аргументов
CREATE_SERVICE=false
START_SERVICE=false
SIMPLE_START=false
for arg in "$@"; do
    case $arg in
        --service)
            CREATE_SERVICE=true
            shift
            ;;
        --start)
            START_SERVICE=true
            shift
            ;;
        --simple-start)
            SIMPLE_START=true
            shift
            ;;
        *)
            ;;
    esac
done

# Проверка прав sudo
if ! sudo -v; then
    error "Не удалось получить sudo. Скрипт требует прав суперпользователя."
fi

# Определяем имя реального пользователя
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

# ----------------------------------------------------------------------
# Этап 1: Обновление списка пакетов и установка базовых пакетов
# ----------------------------------------------------------------------
info "Обновление пакетов..."
sudo apt update
sudo apt autoremove -y
sudo apt install -y python3 python3-pip python3-venv git wget software-properties-common pciutils ffmpeg

# ----------------------------------------------------------------------
# Этап 2: Проверка/установка драйвера NVIDIA
# ----------------------------------------------------------------------
info "Проверка драйвера NVIDIA..."

# Функция определения модели GPU через lspci
detect_gpu_model() {
    if ! command -v lspci &> /dev/null; then
        sudo apt install -y pciutils
    fi
    local gpu_info
    gpu_info=$(lspci | grep -i nvidia | head -n1)
    if [[ -z "$gpu_info" ]]; then
        echo ""
    else
        echo "$gpu_info" | sed -E 's/.*: (.*) \(.*/\1/' | sed 's/ *$//'
    fi
}

# Функция проверки совместимости драйвера с CUDA 13
check_nvidia_driver() {
    if ! command -v nvidia-smi &> /dev/null; then
        return 1
    fi
    local driver_version
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
    if [[ -z "$driver_version" ]]; then
        return 1
    fi
    if [[ "$(echo "$driver_version" | cut -d. -f1)" -ge 525 ]]; then
        return 0
    else
        warn "Драйвер версии $driver_version может не поддерживать CUDA 13. Рекомендуется обновление."
        return 1
    fi
}

if check_nvidia_driver; then
    info "Драйвер NVIDIA уже установлен и совместим с CUDA 13. Пропускаем этап установки драйвера."
else
    warn "Драйвер NVIDIA не обнаружен или устарел. Определяем модель GPU для выбора подходящего драйвера."
    
    GPU_MODEL=$(detect_gpu_model)
    if [[ -z "$GPU_MODEL" ]]; then
        warn "Не удалось определить модель GPU через lspci. Будет использован драйвер по умолчанию nvidia-driver-590-server."
        DRIVER_PACKAGE="nvidia-driver-590-server"
    else
        info "Обнаружена видеокарта: $GPU_MODEL"
        if [[ "$GPU_MODEL" == *"V100"* ]] || [[ "$GPU_MODEL" == *"Tesla V100"* ]]; then
            info "Для Tesla V100 рекомендуется драйвер nvidia-driver-535-server."
            DRIVER_PACKAGE="nvidia-driver-535-server"
        else
            info "Для данной карты будет установлен драйвер nvidia-driver-590-server."
            DRIVER_PACKAGE="nvidia-driver-590-server"
        fi
    fi

    info "Удаление предыдущих версий драйверов NVIDIA..."
    sudo apt purge ^nvidia-* -y || true
    sudo apt purge ^libnvidia-* -y || true
    sudo apt autoremove -y
    sudo apt clean

    sudo add-apt-repository -y restricted
    sudo add-apt-repository -y multiverse

    info "Установка драйвера $DRIVER_PACKAGE (требуется перезагрузка)..."
    sudo apt install -y "$DRIVER_PACKAGE"

    warn "Драйвер установлен. Необходимо перезагрузить систему для загрузки модулей ядра."
    warn "После перезагрузки запустите этот скрипт снова для продолжения установки."
    
    read -rp "Перезагрузить сейчас? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        exit 0
    else
        error "Перезагрузка обязательна. Запустите скрипт после перезагрузки."
    fi
fi

info "Драйвер NVIDIA работает:"
nvidia-smi

# ----------------------------------------------------------------------
# Этап 3: Клонирование ComfyUI и создание виртуального окружения
# ----------------------------------------------------------------------
info "Клонирование ComfyUI..."
COMFYUI_DIR="$REAL_HOME/ComfyUI"
if [ -d "$COMFYUI_DIR" ]; then
    warn "Директория $COMFYUI_DIR уже существует. Используем её."
else
    info "Клонирование ComfyUI..."
    sudo -u "$REAL_USER" git clone https://github.com/Comfy-Org/ComfyUI.git "$COMFYUI_DIR"
fi

cd "$COMFYUI_DIR"

if [ ! -d ".venv" ]; then
    info "Создание виртуального окружения Python..."
    sudo -u "$REAL_USER" python3 -m venv .venv
fi

source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# ----------------------------------------------------------------------
# Этап 4: Установка кастомных нод (параллельно)
# ----------------------------------------------------------------------
info "Установка кастомных нод..."
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
mkdir -p "$CUSTOM_NODES_DIR"
cd "$CUSTOM_NODES_DIR"

info "Клонирование кастомных нод (параллельно)..."
pids=()

clone_repo() {
    local repo_url=$1
    local dir_name=$(basename "$repo_url" .git)
    if [ -d "$dir_name" ]; then
        warn "Папка $dir_name уже существует, пропускаем клонирование."
    else
        sudo -u "$REAL_USER" git clone "$repo_url" &
        pids+=($!)
    fi
}

clone_repo "https://github.com/Comfy-Org/ComfyUI-Manager.git"
clone_repo "https://github.com/romandev-codex/ComfyUI-Downloader.git"
clone_repo "https://github.com/MoonGoblinDev/Civicomfy.git"
clone_repo "https://github.com/crystian/ComfyUI-Crystools.git"

if [ ${#pids[@]} -gt 0 ]; then
    wait "${pids[@]}"
fi

info "Установка зависимостей кастомных нод..."
cd "$COMFYUI_DIR"
source .venv/bin/activate

install_custom_node_deps() {
    local node_dir=$1
    local node_name=$(basename "$node_dir")
    
    if [ -f "$node_dir/requirements.txt" ]; then
        info "Установка зависимостей для $node_name..."
        pip install -r "$node_dir/requirements.txt" || warn "Не удалось установить зависимости для $node_name"
    fi
    
    if [ -f "$node_dir/setup.py" ] || [ -f "$node_dir/pyproject.toml" ]; then
        info "Установка $node_name через pip install -e..."
        pip install -e "$node_dir" || warn "Не удалось установить $node_name"
    fi
}

for node_dir in "$CUSTOM_NODES_DIR"/*; do
    if [ -d "$node_dir" ]; then
        install_custom_node_deps "$node_dir"
    fi
done

# ----------------------------------------------------------------------
# Этап 5: Установка CUDA Toolkit 13.0
# ----------------------------------------------------------------------
info "Установка CUDA 13..."
info "Установка CUDA Toolkit 13.0 из репозитория NVIDIA..."
cd /tmp
if [ ! -f "cuda-keyring_1.1-1_all.deb" ]; then
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
fi
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y cuda-toolkit-13-0

# ----------------------------------------------------------------------
# Этап 6: Установка PyTorch для CUDA 13.0
# ----------------------------------------------------------------------
info "Установка PyTorch..."
cd "$COMFYUI_DIR"
source .venv/bin/activate

info "Установка PyTorch 2.9.1 с поддержкой CUDA 13.0..."
pip install torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/cu130

# ----------------------------------------------------------------------
# Этап 7: Сборка и установка SageAttention из исходников
# ----------------------------------------------------------------------
info "Сборка SageAttention..."
info "Клонирование репозитория SageAttention..."
cd "$COMFYUI_DIR"
if [ ! -d "SageAttention" ]; then
    sudo -u "$REAL_USER" git clone https://github.com/thu-ml/SageAttention.git
fi
cd SageAttention

if git rev-parse v2.2.0 >/dev/null 2>&1; then
    sudo -u "$REAL_USER" git checkout v2.2.0
else
    warn "Тег v2.2.0 не найден, используется ветка по умолчанию (main)."
fi

info "Настройка параметров компиляции SageAttention..."
export EXT_PARALLEL=4
export NVCC_APPEND_FLAGS="--threads 8"
CORES=$(nproc)
MAX_JOBS=$((CORES * 2))
export MAX_JOBS

info "Компиляция SageAttention с MAX_JOBS=$MAX_JOBS..."
python setup.py install

# ----------------------------------------------------------------------
# Этап 8: Создание скрипта запуска run_comfyui.sh в домашней папке
# ----------------------------------------------------------------------
info "Создание скрипта запуска..."
RUN_SCRIPT="$REAL_HOME/run_comfyui.sh"

cat > "$RUN_SCRIPT" << EOF
#!/usr/bin/env bash
# Скрипт для запуска ComfyUI с активацией виртуального окружения и флагами --listen --port

COMFYUI_DIR="\$HOME/ComfyUI"

if [ ! -d "\$COMFYUI_DIR" ]; then
    echo "Ошибка: директория \$COMFYUI_DIR не найдена."
    exit 1
fi

cd "\$COMFYUI_DIR"

if [ ! -f ".venv/bin/activate" ]; then
    echo "Ошибка: виртуальное окружение не найдено."
    exit 1
fi

source .venv/bin/activate

# Запуск с флагами --listen 0.0.0.0 --port 8188 --use-sage-attention
python main.py --listen 0.0.0.0 --port 8188 --use-sage-attention "\$@"
EOF

chmod +x "$RUN_SCRIPT"
chown "$REAL_USER":"$REAL_USER" "$RUN_SCRIPT"
info "Скрипт запуска создан: $RUN_SCRIPT"

# ----------------------------------------------------------------------
# Этап 9: Создание systemd-сервиса (если указан --service)
# ----------------------------------------------------------------------
if [ "$CREATE_SERVICE" = true ]; then
    info "Создание systemd-сервиса..."

    SERVICE_FILE="/etc/systemd/system/comfyui.service"
    sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=ComfyUI Service
After=network.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$COMFYUI_DIR
ExecStart=$REAL_HOME/run_comfyui.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable comfyui.service
    info "Сервис comfyui.service создан и включён."

    if [ "$START_SERVICE" = true ]; then
        info "Запуск сервиса comfyui.service..."
        sudo systemctl start comfyui.service
        info "Сервис запущен."
    fi
else
    if [ "$START_SERVICE" = true ]; then
        warn "Флаг --start указан, но сервис не был создан (отсутствует --service). Запуск невозможен."
    fi
fi

# ----------------------------------------------------------------------
# Завершение
# ----------------------------------------------------------------------
info "Установка успешно завершена!"
info "Для запуска ComfyUI используйте: $RUN_SCRIPT"
info "Или активируйте окружение вручную: cd ~/ComfyUI && source .venv/bin/activate && python main.py"

# Запуск run_comfyui.sh если указан --simple-start
if [ "$SIMPLE_START" = true ]; then
    info "Запуск ComfyUI..."
    exec "$RUN_SCRIPT"
fi
