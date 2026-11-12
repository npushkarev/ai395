#!/usr/bin/env bash
# Настройка AMD Ryzen AI Max+ 395 (Strix Halo, Radeon 8060S / gfx1151) под нейросети.
# Ubuntu 24.04+/26.04. Запускать обычным пользователем с sudo, НЕ от root.
#
#   ./setup-ai395.sh                 # всё по порядку (долгую загрузку лучше запускать в tmux)
#   ./setup-ai395.sh models halogen  # отдельные шаги
#   ./setup-ai395.sh verify
#
# Шаги: system nosleep docker llama models halogen halo-coder ollama pytorch verify
# По умолчанию движок — halogen (ENGINE=halogen), halo-coder на llama.cpp — запасной (ENGINE=llama).
# Каждый шаг можно перезапускать: уже сделанное он пропустит.
set -Eeuo pipefail
# Ни одна ошибка не должна проходить молча: печатаем, где и что упало (130 = Ctrl+C, о нём уже сказано)
trap 'rc=$?; ((rc == 130)) || echo "✗ ошибка (код $rc): строка $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai395.conf
# Переменные из окружения (CTX=131072 ./setup-ai395.sh …) важнее конфига
_env_saved=$(export -p)
[[ -f "$SCRIPT_DIR/ai395.conf" ]] && source "$SCRIPT_DIR/ai395.conf"
eval "$_env_saved"; unset _env_saved

# Значения по умолчанию, если конфига нет
: "${AI_HOME:=$HOME/ai395}" "${MODEL_DIR:=$HOME/models/qwen38unc}" "${OLLAMA_MODELS_DIR=}"
: "${AMD_IOMMU_OFF:=1}" "${SWAP_GB:=32}" "${DISABLE_ZSWAP:=1}" "${ENGINE:=halogen}"
: "${HG_IMAGE:=ghcr.io/peonist-ai/halogen-flash-server:0.20.1}" "${HG_PUBLISH:=0.0.0.0:8731}" "${HG_API_KEY:=1}"
: "${HG_WEIGHTS_REPO:=peonist-ai/halogen-qwen3.8-flash-next}" "${HG_EXTRA_ENV:=}" "${HG_MODEL:=fast}"
: "${HF_HUB_PIN:=huggingface_hub==1.17.0}"
: "${LLAMA_REPO:=https://github.com/ggml-org/llama.cpp.git}" "${LLAMA_REF:=b11627}"
: "${MODEL_REPO:=mradermacher/Qwen3.8-Flash-Next-Uncensored-i1-GGUF}"
: "${MODEL_FILE:=Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf}"
: "${MTP:=1}" "${MTP_REPO:=ggml-org/Qwen3.8-Flash-Next-GGUF}" "${MTP_FILE:=mtp-Qwen3.8-Flash-Next-Q8_0.gguf}"
: "${MTP_REQUANT:=1}" "${QSA:=1}"
: "${HC_ALIAS:=qwen38-flash-next-unc}" "${HC_HOST:=127.0.0.1}" "${HC_PORT:=8088}"
: "${CTX:=262144}" "${SLOTS:=1}" "${CACHE_RAM_MIB:=2048}" "${UBATCH:=512}"
: "${DRAFT_N_MAX:=3}" "${DRAFT_P_MIN:=0.75}" "${WATCHDOG:=1}"
: "${OLLAMA_BIND:=127.0.0.1:11434}" "${OLLAMA_CTX:=8192}" "${OLLAMA_KEEP_ALIVE:=1m}" "${OLLAMA_AUTOSTART:=auto}" "${OLLAMA_PULL:=}"
: "${TORCH_INDEX:=https://rocm.nightlies.amd.com/v2/gfx1151/}" "${TORCH_PYTHON:=3.12}"

BIN_DIR="$AI_HOME/bin"
TOOLS_VENV="$AI_HOME/venv-tools"
TORCH_VENV="$AI_HOME/venv-torch"
LOG_DIR="$AI_HOME/logs"
REBOOT_NEEDED=0
# Токенайзер halogen (нужен и v2, и GGUF)
HG_TOKENIZER_FILES=(tokenizer/chat_template.jinja tokenizer/generation_config.json tokenizer/merges.txt
                    tokenizer/tokenizer.json tokenizer/tokenizer_config.json tokenizer/vocab.json)

# ── утилиты ──────────────────────────────────────────────────────────
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_h=$'\e[1;36m'; c_0=$'\e[0m'
step() { echo; echo "${c_h}══ $* ══${c_0}"; }
ok()   { echo "${c_ok}✓${c_0} $*"; }
warn() { echo "${c_warn}!${c_0} $*"; }
die()  { echo "${c_err}✗ $*${c_0}" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# пакет, которого может не быть в этой версии Ubuntu — ставим, если есть
apt_try() {
  local p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then apt_install "$p"; else warn "пакета $p нет в репозитории — пропускаю"; fi
  done
}

# sudo-rs (Ubuntu 26.04) помнит пароль 15 минут, а ввода ждёт 5 минут. Загрузка моделей идёт часами,
# поэтому без поддержки метки шаг halogen после неё упал бы на запросе пароля, пока никого нет рядом.
sudo_keepalive() {
  sudo -v || die "нужен sudo"
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 60; done ) &
  SUDO_KA_PID=$!
  trap 'kill "$SUDO_KA_PID" 2>/dev/null || true' EXIT
}

preflight() {
  [[ $EUID -ne 0 ]] || die "запускай обычным пользователем (sudo скрипт спросит сам)"
  if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
  [[ "${ID:-}" == ubuntu ]] || warn "скрипт писался под Ubuntu, а тут ${PRETTY_NAME:-неизвестно}"
  grep -qi "AMD Ryzen AI MAX" /proc/cpuinfo || warn "это не Ryzen AI Max — параметры памяти могут не подойти"
  sudo_keepalive
  mkdir -p "$AI_HOME" "$BIN_DIR" "$LOG_DIR"
}

ensure_uv() {
  have uv && return 0
  [[ -x "$HOME/.local/bin/uv" ]] || curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
}

# huggingface_hub закреплён на 1.17.0: начиная с 1.18 (и в 2.x) прерванная загрузка начинается заново,
# а 1.17 с HF_HUB_DISABLE_XET=1 докачивает .incomplete с того же места — для 112 ГиБ это важно.
ensure_tools_venv() {
  ensure_uv
  [[ -x "$TOOLS_VENV/bin/python" ]] || uv venv -q --python "$TORCH_PYTHON" "$TOOLS_VENV"
  uv pip install -q --python "$TOOLS_VENV/bin/python" "$HF_HUB_PIN" gguf numpy
}

# 2.x при обрыве оставлял <hash>.<etag>.<uuid8>.incomplete, которые никто не докачивает и не удаляет
clean_hf_orphans() {
  local d="$MODEL_DIR/.cache/huggingface/download" f
  [[ -d "$d" ]] || return 0
  if pgrep -u "$(id -u)" -f 'hf download' >/dev/null; then return 0; fi   # кто-то качает прямо сейчас
  while IFS= read -r -d '' f; do
    if [[ "$(basename "$f")" =~ \.[0-9a-f]{8}\.incomplete$ ]]; then rm -f "$f"; fi
  done < <(find "$d" -name '*.incomplete' -print0 2>/dev/null)
  return 0
}

# hf download с понятным прогрессом: «скачано X из Y ГиБ · скорость · осталось ~N мин» раз в 20 с.
# Ctrl+C / закрытие окна останавливают и загрузку; повторный запуск докачает с того же места.
hf_get() {
  local repo=$1; shift
  clean_hf_orphans
  HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_PROGRESS_BARS=1 \
    "$TOOLS_VENV/bin/hf" download "$repo" "$@" --local-dir "$MODEL_DIR" &
  local dl=$!
  local st="$LOG_DIR/download.status"
  mkdir -p "$LOG_DIR"
  DL_STATUS_FILE="$st" "$TOOLS_VENV/bin/python" "$SCRIPT_DIR/dl_progress.py" "$repo" "$MODEL_DIR" "$dl" "$@" &
  local mon=$!
  trap "kill $dl $mon 2>/dev/null; rm -f '$st'; echo; echo 'прервано — запусти ещё раз, докачает с того же места'; exit 130" INT TERM HUP
  local rc=0
  wait "$dl" || rc=$?
  kill "$mon" 2>/dev/null || true   # индикатор мог уже выйти сам
  wait "$mon" 2>/dev/null || true
  trap - INT TERM HUP
  rm -f "$st"
  ((rc == 0)) || die "загрузка $repo прервалась (код $rc) — запусти ещё раз, докачает с того же места"
}

# Какую модель держит halogen: выбор из ./halogen-fast.sh важнее конфига
hg_choice() { cat "$AI_HOME/halogen.choice" 2>/dev/null || echo "$HG_MODEL"; }

mem_total_kb() { awk '/^MemTotal:/ {print $2}' /proc/meminfo; }

container_status() { sudo docker inspect -f '{{.State.Status}}' halogen 2>/dev/null || true; }

# docker pull с видимым ходом: по строке на каждый скачанный и распакованный слой (26 слоёв, ~0.9 ГиБ)
pull_image() {
  if sudo docker image inspect "$HG_IMAGE" >/dev/null 2>&1; then return 0; fi
  echo "качаю образ $HG_IMAGE (~0.9 ГиБ, на 5 МБ/с — минуты 3–4; ниже по строке на каждый готовый слой)…"
  sudo docker pull "$HG_IMAGE" 2>&1 | { grep --line-buffered -E 'Download complete|Pull complete|Status:|Digest:|rror' || true; }
  sudo docker image inspect "$HG_IMAGE" >/dev/null 2>&1   # итог — есть ли образ, а не что напечатал pull
}

# ── 1. система: пакеты, драйвер, память iGPU, swap, группы ───────────
make_swapfile() {
  local f=$1
  if [[ "$(findmnt -no FSTYPE /)" == btrfs ]]; then
    sudo btrfs filesystem mkswapfile --size "${SWAP_GB}g" "$f"   # fallocate на btrfs даёт «Invalid argument»
  else
    sudo fallocate -l "${SWAP_GB}G" "$f" && sudo chmod 600 "$f" && sudo mkswap "$f" >/dev/null
  fi
}

do_system() {
  step "Система"
  sudo apt-get update -q
  apt_install build-essential cmake ninja-build git git-lfs ccache pkg-config curl ca-certificates openssl \
              libcurl4-openssl-dev libssl-dev python3 python3-venv jq htop nvtop pciutils tmux \
              mesa-vulkan-drivers vulkan-tools libvulkan-dev glslc spirv-headers \
              linux-firmware radeontop power-profiles-daemon
  apt_try rocminfo rocm-smi amdgpu-top

  # Группы для доступа к /dev/kfd и /dev/dri
  local g
  for g in render video; do
    if ! id -nG "$USER" | grep -qw "$g"; then sudo usermod -aG "$g" "$USER"; REBOOT_NEEDED=1; ok "добавлен в группу $g"; fi
  done

  # Память iGPU. На Strix Halo VRAM — это кусок ОЗУ; всё, что не carveout из BIOS, iGPU берёт динамически
  # через GTT. Потолок GTT задаёт ttm.pages_limit (страницы по 4 КиБ) — ставим «около всего ОЗУ», как советуют
  # авторы halogen (docs/troubleshooting.md). amdgpu.gttsize не нужен: в ядре 7.0 он deprecated в пользу
  # ttm.pages_limit. Флаги vm_update_mode/noretry/sg_display авторы сами не рекомендуют — не ставим.
  # Размер считаем от целых ГиБ: MemTotal между версиями ядра «гуляет» на килобайты.
  local total_kb gib pages params
  total_kb=$(mem_total_kb)
  gib=$(( total_kb / 1048576 ))
  pages=$(( gib * 262144 ))
  params="ttm.pages_limit=$pages"
  if ((AMD_IOMMU_OFF)); then params+=" amd_iommu=off"; else params+=" iommu=pt"; fi
  if ((DISABLE_ZSWAP)); then params+=" zswap.enabled=0"; fi
  local cfg=/etc/default/grub.d/90-ai395.cfg
  local want="GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $params\""
  if [[ "$(cat "$cfg" 2>/dev/null)" != "$want" ]]; then
    sudo mkdir -p /etc/default/grub.d
    echo "$want" | sudo tee "$cfg" >/dev/null
    sudo update-grub
    REBOOT_NEEDED=1
    ok "параметры ядра: $params (GTT до $gib ГиБ)"
  else
    ok "параметры ядра уже стоят"
  fi
  if ((DISABLE_ZSWAP)) && [[ -e /sys/module/zswap/parameters/enabled ]]; then
    echo N | sudo tee /sys/module/zswap/parameters/enabled >/dev/null 2>&1 || true   # и сразу, без перезагрузки
  fi

  # Carveout из BIOS: если он большой, эта память потеряна для GTT и для системы
  local vram
  vram=$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -n | tail -1 || true)
  vram=${vram:-0}
  if (( vram > 4 * 1024 ** 3 )); then
    warn "в BIOS отдано под iGPU $(( vram / 1024 ** 3 )) ГиБ (UMA Frame Buffer Size)."
    warn "поставь 512M–2G: под Linux iGPU всё равно берёт память через GTT, а так вернёшь $(( vram / 1024 ** 3 - 2 ))+ ГиБ."
  fi

  # Страховочный swap: под почти полным контекстом пик памяти выше ОЗУ. Не критичен — без места не роняем установку.
  local swf=/swapfile-llm
  if ((SWAP_GB > 0)) && ! grep -q "^$swf " /proc/swaps; then
    if [[ -f $swf ]] && sudo swapon "$swf" 2>/dev/null; then
      :
    elif sudo rm -f "$swf" && make_swapfile "$swf" && sudo swapon "$swf"; then
      :
    else
      sudo rm -f "$swf"
      warn "swap-файл $swf на ${SWAP_GB} ГБ не создан (мало места на диске?) — продолжаю без него"
    fi
    if grep -q "^$swf " /proc/swaps; then
      grep -q "^$swf " /etc/fstab || echo "$swf none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab >/dev/null
      ok "swap $swf ${SWAP_GB} ГБ"
    fi
  fi

  sudo tee /etc/sysctl.d/90-ai395.conf >/dev/null <<'EOF'
vm.swappiness=10
vm.max_map_count=1048576
vm.overcommit_memory=0
EOF
  sudo sysctl -q --system

  # Лимит залоченной памяти — для --mlock и ROCm
  sudo tee /etc/security/limits.d/90-ai395.conf >/dev/null <<EOF
$USER soft memlock unlimited
$USER hard memlock unlimited
EOF

  if have powerprofilesctl; then
    if powerprofilesctl set performance 2>/dev/null; then ok "профиль питания: performance"; else warn "не удалось включить performance"; fi
  fi

  sudo loginctl enable-linger "$USER"
  ok "система готова"
}

# ── 2. Docker с доступом к iGPU ──────────────────────────────────────
do_docker() {
  step "Docker"
  if ! have docker; then
    apt_install docker.io
    apt_try docker-compose-v2 docker-buildx
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
  fi

  # При загрузке dockerd может стартовать раньше, чем появятся /dev/kfd и /dev/dri (amdgpu).
  # Тогда контейнер halogen с --device не стартует, и Docker повторять не будет — подождём их (до 60 с).
  sudo tee /usr/local/sbin/ai395-wait-gpu >/dev/null <<'EOF'
#!/bin/sh
i=0
while [ "$i" -lt 60 ]; do
  if [ -e /dev/kfd ] && ls /dev/dri/renderD* >/dev/null 2>&1; then exit 0; fi
  sleep 1; i=$((i + 1))
done
exit 0
EOF
  sudo chmod +x /usr/local/sbin/ai395-wait-gpu
  sudo mkdir -p /etc/systemd/system/docker.service.d
  printf '[Service]\nExecStartPre=/usr/local/sbin/ai395-wait-gpu\n' \
    | sudo tee /etc/systemd/system/docker.service.d/10-ai395-wait-gpu.conf >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now docker
  if ! id -nG "$USER" | grep -qw docker; then sudo usermod -aG docker "$USER"; REBOOT_NEEDED=1; fi

  # Обёртка: контейнер с доступом к iGPU (ROCm через /dev/kfd, Vulkan через /dev/dri).
  # Группы передаём числами: имена Docker ищет в /etc/group ОБРАЗА, а группы render там обычно нет (exit 125).
  cat > "$BIN_DIR/docker-gpu" <<'EOF'
#!/usr/bin/env bash
# docker-gpu <образ> [команда] — docker run с проброшенным iGPU Strix Halo
gadd=()
for g in $(stat -c %g /dev/kfd /dev/dri/renderD* 2>/dev/null | sort -u); do gadd+=(--group-add "$g"); done
exec docker run --rm -it \
  --device /dev/kfd --device /dev/dri "${gadd[@]}" \
  --security-opt seccomp=unconfined --ipc=host \
  -e HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-}" \
  -v "$HOME/models:/models" "$@"
EOF
  chmod +x "$BIN_DIR/docker-gpu"

  # Образ halogen тянем сразу (0.9 ГиБ): проблемы с сетью до ghcr.io всплывут до многочасовой загрузки моделей
  if [[ "$ENGINE" == halogen ]]; then
    if pull_image; then ok "образ halogen скачан: $HG_IMAGE"
    else warn "не удалось скачать $HG_IMAGE (сеть до ghcr.io?) — попробую ещё раз на шаге halogen"; fi
  fi
  ok "docker готов; GPU в контейнер: $BIN_DIR/docker-gpu <образ> (нужен перелогин для группы docker)"
}

# ── 3. llama.cpp (Vulkan, статически) ────────────────────────────────
do_llama() {
  step "llama.cpp $LLAMA_REF (Vulkan)"
  local src="$AI_HOME/src/llama.cpp" dst="$BIN_DIR/llama-$LLAMA_REF" t
  if [[ -x "$dst/llama-server" ]]; then
    ok "уже собран: $dst"
  else
    if [[ ! -d "$src/.git" ]]; then
      git clone --filter=blob:none "$LLAMA_REPO" "$src"
    fi
    git -C "$src" fetch --tags -q origin
    git -C "$src" checkout -q --detach "$LLAMA_REF"
    # Статически: динамическая сборка, скопированная из build/, падает «libllama-server-impl.so: cannot open»
    cmake -S "$src" -B "$src/build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_VULKAN=ON -DGGML_NATIVE=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    # -j по числу ядер минус 4, чтобы не мешать работающему инференсу
    cmake --build "$src/build" -j "$(( $(nproc) > 8 ? $(nproc) - 4 : $(nproc) ))" \
      --target llama-server llama-cli llama-bench llama-quantize llama-gguf-split
    mkdir -p "$dst"
    for t in llama-server llama-cli llama-bench llama-quantize llama-gguf-split; do
      cp "$src/build/bin/$t" "$dst/"
    done
    ok "собрано в $dst"
  fi
  # Атомарно переключаем «текущую» версию; запущенный сервер держит старый inode и не ломается
  ln -sfn "llama-$LLAMA_REF" "$BIN_DIR/llama-current"
  local devs; devs=$("$BIN_DIR/llama-current/llama-server" --list-devices 2>&1 || true)
  if grep -qE "Vulkan|Radeon" <<<"$devs"; then
    grep -E "Vulkan|Radeon" <<<"$devs" || true
  else
    warn "llama-server не видит Vulkan-устройство — проверь группу render и mesa"
  fi
}

# ── 4. Веса Qwen3.8-Flash-Next ───────────────────────────────────────
model_path() { local f="$MODEL_DIR/$MODEL_FILE"; if ((QSA)); then f="${f%.gguf}.qsa.gguf"; fi; echo "$f"; }
mtp_path()   { local f="$MODEL_DIR/$MTP_FILE"; if ((MTP_REQUANT)); then f="${f%.gguf}-output-q5_k.gguf"; fi; echo "$f"; }

do_models() {
  step "Модели"
  if [[ "$ENGINE" == halogen && "$(hg_choice)" == fast ]]; then
    "$SCRIPT_DIR/halogen-fast.sh" download   # чекпоинт halogen v2, GGUF не нужен
    return 0
  fi
  ensure_tools_venv
  mkdir -p "$MODEL_DIR"
  clean_hf_orphans
  local avail_gb
  avail_gb=$(df -BG --output=avail "$MODEL_DIR" | tail -1 | tr -dc 0-9)
  (( avail_gb > 120 )) || warn "на $MODEL_DIR свободно ${avail_gb} ГБ — может не хватить (модель + QSA-копия на не-btrfs)"

  if [[ ! -f "$MODEL_DIR/$MODEL_FILE" ]]; then
    curl -sf -m 20 -o /dev/null "https://huggingface.co/api/models/$MODEL_REPO" \
      || die "нет доступа к huggingface.co — проверь интернет/прокси"
    echo "качаю $MODEL_REPO/$MODEL_FILE (десятки ГБ; можно прервать — докачает с того же места)"
    hf_get "$MODEL_REPO" "$MODEL_FILE"
  fi
  ok "основная модель: $MODEL_DIR/$MODEL_FILE"

  if [[ "$ENGINE" != llama ]]; then
    ok "для halogen хватит исходного GGUF: QSA-копия и MTP-голова llama.cpp не нужны"
    return 0
  fi

  if ((QSA)); then
    local q; q=$(model_path)
    if [[ ! -f "$q" ]]; then
      cp --reflink=auto "$MODEL_DIR/$MODEL_FILE" "$q.tmp"   # на btrfs/xfs — мгновенно и без места
      "$TOOLS_VENV/bin/python" "$SCRIPT_DIR/qsa_patch.py" "$q.tmp"
      mv "$q.tmp" "$q"
    fi
    ok "QSA-копия: $q (оригинал не тронут)"
  fi

  if ((MTP)); then
    [[ -f "$MODEL_DIR/$MTP_FILE" ]] || hf_get "$MTP_REPO" "$MTP_FILE"
    if ((MTP_REQUANT)); then
      local m; m=$(mtp_path)
      if [[ ! -f "$m" ]]; then
        [[ -x "$BIN_DIR/llama-current/llama-quantize" ]] || do_llama
        # output.weight — ≈82% байтов на драфт-токен; Q5_K быстрее при той же точности драфта
        "$BIN_DIR/llama-current/llama-quantize" --allow-requantize \
          --output-tensor-type q5_k --tensor-type indexer=bf16 \
          "$MODEL_DIR/$MTP_FILE" "$m" Q8_0 >"$LOG_DIR/mtp-quantize.log" 2>&1 \
          || { warn "пережатие головы не вышло (лог $LOG_DIR/mtp-quantize.log) — беру исходную"; cp --reflink=auto "$MODEL_DIR/$MTP_FILE" "$m"; }
      fi
    fi
    ok "MTP-голова: $(mtp_path)"
  fi
}

# ── 5. halo-coder: llama-server как системная служба ─────────────────
do_halo_coder() {
  step "halo-coder"
  if have docker && sudo docker inspect halogen >/dev/null 2>&1; then
    warn "останавливаю halogen (штатно, до 60 с): вдвоём с halo-coder память не поделят"
    sudo docker update --restart=no halogen >/dev/null 2>&1 || true
    sudo docker stop -t 60 halogen >/dev/null 2>&1 || true
  fi
  local server="$BIN_DIR/llama-current/llama-server"
  [[ -x "$server" ]] || do_llama
  local model; model=$(model_path)
  [[ -f "$model" ]] || do_models

  # Флаги между версиями llama.cpp переименовывались (b11900: --draft-max → --spec-draft-n-max),
  # поэтому выбираем по --help той сборки, что реально стоит.
  local help; help=$("$server" --help 2>&1 || true)
  has() { grep -qe "$1" <<<"$help"; }

  local args=(
    -m "$model" --alias "$HC_ALIAS"
    --host "$HC_HOST" --port "$HC_PORT"
    -c "$CTX" -np "$SLOTS" -ngl 999 -ub "$UBATCH"
    -ctk q8_0 -ctv q8_0 --jinja
  )
  if has '--flash-attn'; then args+=(-fa on); fi
  if has '--cache-ram'; then args+=(--cache-ram "$CACHE_RAM_MIB"); fi

  if ((MTP)); then
    local mtp; mtp=$(mtp_path)
    if has '--spec-type'; then args+=(--spec-type draft-mtp); fi
    args+=(-md "$mtp" -ngld 999)
    if has '--spec-draft-n-max'; then
      args+=(--spec-draft-n-max "$DRAFT_N_MAX" --spec-draft-p-min "$DRAFT_P_MIN")
    else
      args+=(--draft-max "$DRAFT_N_MAX" --draft-p-min "$DRAFT_P_MIN")
    fi
    if has '-ctkd'; then args+=(-ctkd q8_0 -ctvd q8_0); fi   # иначе KV драфта в f16
  fi

  local unit=/etc/systemd/system/halo-coder.service
  # Системная служба, не --user: в user-юните отрицательный OOMScoreAdjust не применяется,
  # и при нехватке памяти ядро убило бы именно llama-server.
  sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=halo-coder — llama-server, $HC_ALIAS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$(id -gn)
SupplementaryGroups=render video
WorkingDirectory=$AI_HOME
ExecStart=$server ${args[*]}
Restart=always
RestartSec=15
TimeoutStopSec=60
OOMScoreAdjust=-500
LimitMEMLOCK=infinity
LimitNOFILE=65536
StandardOutput=append:$LOG_DIR/halo-coder.log
StandardError=append:$LOG_DIR/halo-coder.log

[Install]
WantedBy=multi-user.target
EOF

  if ((WATCHDOG)); then
    # /health отвечает 200 даже когда движок завис под полным контекстом; /slots в этом
    # состоянии молчит. Генерацию для проверки не шлём — она сбивает KV живых клиентов.
    sudo tee /usr/local/bin/halo-coder-watchdog >/dev/null <<EOF
#!/usr/bin/env bash
state=/run/halo-coder-watchdog.fails
systemctl is-active -q halo-coder || exit 0
up=\$(( \$(date +%s) - \$(date -d "\$(systemctl show -p ActiveEnterTimestamp --value halo-coder)" +%s) ))
(( up > 900 )) || exit 0          # первые 15 минут — загрузка модели
if curl -sf -m 60 http://127.0.0.1:$HC_PORT/slots >/dev/null; then echo 0 >"\$state"; exit 0; fi
n=\$(( \$(cat "\$state" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$state"
logger -t halo-coder-watchdog "/slots не отвечает (\$n из 3)"
if (( n >= 3 )); then echo 0 >"\$state"; logger -t halo-coder-watchdog "перезапуск"; systemctl restart halo-coder; fi
EOF
    sudo chmod +x /usr/local/bin/halo-coder-watchdog
    sudo tee /etc/systemd/system/halo-coder-watchdog.service >/dev/null <<'EOF'
[Unit]
Description=halo-coder watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/halo-coder-watchdog
EOF
    sudo tee /etc/systemd/system/halo-coder-watchdog.timer >/dev/null <<'EOF'
[Unit]
Description=halo-coder watchdog каждые 3 минуты
[Timer]
OnBootSec=10min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
EOF
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable halo-coder
  if ((WATCHDOG)); then sudo systemctl enable --now halo-coder-watchdog.timer; fi
  # Без ttm.pages_limit лимит GTT ≈ половина ОЗУ — модель не влезет. Служба уже enabled
  # и сама поднимется после перезагрузки.
  if ! grep -q 'ttm.pages_limit=' /proc/cmdline; then
    warn "ядро ещё без ttm.pages_limit — halo-coder запустится сам после перезагрузки"
    REBOOT_NEEDED=1
    return 0
  fi
  sudo systemctl restart halo-coder

  echo "жду загрузку модели (до 10 минут)…"
  local i
  for i in $(seq 1 120); do
    if curl -sf -m 5 "http://127.0.0.1:$HC_PORT/health" >/dev/null; then
      ok "halo-coder поднят: http://$HC_HOST:$HC_PORT/v1  (модель $HC_ALIAS)"
      return 0
    fi
    systemctl is-active -q halo-coder || { tail -30 "$LOG_DIR/halo-coder.log"; die "halo-coder упал при старте"; }
    sleep 5
  done
  warn "за 10 минут не поднялся — смотри: tail -f $LOG_DIR/halo-coder.log"
}

# ── 5a. halogen-flash-server ─────────────────────────────────────────
# Движок, убитый посреди работы на GPU, может оставить за собой 35–45 ГиБ GTT (docs/troubleshooting.md):
# тогда следующий старт отказывает или висит до перезагрузки. Предупредим, если похоже на это.
gtt_leak_check() {
  local used=0 u f
  for f in /sys/class/drm/card*/device/mem_info_gtt_used; do
    [[ -r "$f" ]] || continue
    u=$(<"$f")
    if (( u > used )); then used=$u; fi
  done
  if (( used > 8 * 1024 ** 3 )) && [[ -z "$(ls -A /sys/class/kfd/kfd/proc 2>/dev/null || true)" ]]; then
    warn "GPU держит $(( used / 1024 ** 3 )) ГиБ GTT без вычислительных процессов — похоже на утечку после прошлого запуска."
    warn "если halogen не стартует или висит на «reserving the KV pool» — нужна перезагрузка: sudo reboot"
  fi
  return 0
}

do_halogen() {
  step "halogen-flash-server ($HG_IMAGE)"
  have docker || do_docker
  # Какую модель держит halogen: fast (чекпоинт v2, по умолчанию) или uncensored (GGUF без цензуры)
  local choice ckpt
  choice=$(hg_choice)
  if [[ "$choice" == fast ]]; then
    ckpt="/models/qwen38-flash-next-v2.hgn"
    [[ -f "$MODEL_DIR/qwen38-flash-next-v2.hgn" && -f "$MODEL_DIR/qwen38-flash-next-ngram.hgn" ]] \
      || die "быстрая модель не скачана: ./halogen-fast.sh download"
  else
    ckpt="/models/$MODEL_FILE"
    [[ -f "$MODEL_DIR/$MODEL_FILE" ]] || do_models
    # Драфт-голову и токенайзер halogen качаем сами, от пользователя: контейнер работает от root
    # и оставил бы в томе файлы root:root, на которых потом падает hf download.
    if [[ ! -f "$MODEL_DIR/qwen38-flash-next-mtp.hgn" || ! -f "$MODEL_DIR/tokenizer/tokenizer.json" ]]; then
      ensure_tools_venv
      hf_get "$HG_WEIGHTS_REPO" qwen38-flash-next-mtp.hgn "${HG_TOKENIZER_FILES[@]}"
    fi
  fi
  ok "модель: $choice ($ckpt)"

  if systemctl is-enabled -q halo-coder 2>/dev/null; then
    warn "выключаю halo-coder: вдвоём с halogen память не поделят"
    sudo systemctl disable --now halo-coder halo-coder-watchdog.timer 2>/dev/null || true
  fi

  # Ядро: нужны фиксы KFD под gfx1151 и CONFIG_HSA_AMD_SVM (иначе регистрация весов отказывает)
  local node props="" cap
  for node in /sys/class/kfd/kfd/topology/nodes/*; do
    if grep -q 'gfx_target_version 110501' "$node/properties" 2>/dev/null; then props="$node/properties"; fi
  done
  if [[ -n "$props" ]]; then
    cap=$(awk '$1=="capability"{print $2}' "$props")
    if (( cap & 0x08000000 )); then ok "ядро: KFD SVM есть"; else warn "ядро собрано без CONFIG_HSA_AMD_SVM — halogen не загрузит веса"; fi
    # фиксы на месте, когда cwsr_size = ctl_stack_size + (simd_count / simd_per_cu) * 479232 (docs/troubleshooting.md)
    if awk '$1=="cwsr_size"{c=$2} $1=="ctl_stack_size"{s=$2} $1=="simd_count"{n=$2} $1=="simd_per_cu"{p=$2}
            END{exit !(c != "" && p > 0 && c == s + int(n / p) * 479232)}' "$props"; then
      ok "ядро: фиксы KFD для gfx1151 есть"
    else
      warn "в ядре, похоже, нет фиксов KFD для gfx1151 (нужно ≥ 6.18.4 / Ubuntu 7.0) — halogen может не стартовать"
    fi
  else
    warn "KFD-узел gfx1151 не найден — проверь /dev/kfd и группу render"
  fi

  local env_args=(
    -e "HALOGEN_CHECKPOINT=$ckpt"
    -e "HALOGEN_DOWNLOAD=$HG_WEIGHTS_REPO"   # страховка: докачает недостающее; когда всё на месте — в сеть не ходит
  )
  # Картинки: без этого запрос с изображением получает 400. Башня ~2 ГиБ ОЗУ, пул halogen это учитывает.
  if [[ "$choice" == fast && -f "$MODEL_DIR/qwen38-flash-next-vision.hgn" ]]; then
    env_args+=(-e HALOGEN_VISION_TOWER=1)
  fi
  if ((HG_API_KEY)); then
    local keyf="$AI_HOME/halogen.key"
    if [[ ! -s "$keyf" ]]; then (umask 077; openssl rand -hex 24 >"$keyf"); fi
    chmod 600 "$keyf"   # в контейнере root — ему хватает; другим пользователям бокса ключ не виден
    env_args+=(-e HALOGEN_API_KEY_FILE=/run/halogen.key -v "$keyf:/run/halogen.key:ro")
  fi
  local kv
  for kv in $HG_EXTRA_ENV; do env_args+=(-e "$kv"); done

  # Группы устройств — числами с хоста: имена Docker ищет в /etc/group образа, а группы render
  # в образе halogen нет (docker run падает с кодом 125: «unable to find group render»).
  local gadd=() g
  for g in $(stat -c %g /dev/kfd /dev/dri/renderD* 2>/dev/null | sort -u || true); do gadd+=(--group-add "$g"); done

  local run_args=(
    --name halogen --restart unless-stopped
    --stop-timeout 60            # docker stop/restart/reboot дают движку закончить работу на GPU, а не SIGKILL через 10 с
    -p "$HG_PUBLISH:8731"
    --device /dev/kfd --device /dev/dri "${gadd[@]}"
    --ipc=host --ulimit memlock=-1:-1
    --log-opt max-size=50m --log-opt max-file=3
    "${env_args[@]}"
    -v "$MODEL_DIR:/models"
  )
  local cfg_hash cur
  cfg_hash=$(printf '%s\n' "$HG_IMAGE" "${run_args[@]}" | sha256sum | cut -c1-16)
  cur=$(sudo docker inspect -f '{{index .Config.Labels "ai395.config"}} {{.State.Status}}' halogen 2>/dev/null || true)

  if [[ "$cur" == "$cfg_hash running" ]]; then
    ok "halogen уже работает с этой конфигурацией — не перезапускаю"
  else
    pull_image || die "не удалось скачать образ $HG_IMAGE (сеть до ghcr.io?)"
    if sudo docker inspect halogen >/dev/null 2>&1; then
      echo "останавливаю прежний halogen штатно (до 60 с)…"
      sudo docker update --restart=no halogen >/dev/null 2>&1 || true
      sudo docker stop -t 60 halogen >/dev/null 2>&1 || true
      sudo docker rm halogen >/dev/null 2>&1 || true
      gtt_leak_check
    fi
    # Сразу после записи 112 ГиБ страничный кэш забит — старт может надолго встать на резервировании памяти
    if (( $(awk '/^MemFree:/{print $2}' /proc/meminfo) < 2 * 1024 * 1024 )); then
      sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null || true
    fi
    if ! sudo docker run -d --label "ai395.config=$cfg_hash" "${run_args[@]}" "$HG_IMAGE" >/dev/null; then
      sudo docker rm halogen >/dev/null 2>&1 || true
      die "docker run для halogen не прошёл — причина в сообщении выше"
    fi
  fi

  echo "жду готовности halogen (до 15 минут; обычно меньше минуты)…"
  local i st
  for i in $(seq 1 180); do
    if curl -sf -m 5 -o /dev/null http://127.0.0.1:8731/health; then
      ok "halogen готов: http://$(hostname -I | awk '{print $1}'):8731/v1 (OpenAI) и /v1/messages (Anthropic)"
      if ((HG_API_KEY)); then ok "API-ключ: $AI_HOME/halogen.key"; fi
      sudo docker logs halogen 2>&1 | grep -m3 -E 'host memory left|checkpoint' || true
      return 0
    fi
    # при --restart unless-stopped .State.Running «true» даже в петле перезапусков — смотрим статус и счётчик
    st=$(sudo docker inspect -f '{{.State.Status}} {{.RestartCount}}' halogen 2>/dev/null || echo "нет-контейнера 0")
    if [[ "$st" != "running 0" ]]; then
      sudo docker logs --tail 60 halogen 2>&1 || true
      sudo docker update --restart=no halogen >/dev/null 2>&1 || true
      sudo docker stop -t 60 halogen >/dev/null 2>&1 || true
      die "halogen упал при старте (статус: $st) — лог выше. После исправления: ./setup-ai395.sh halogen"
    fi
    sleep 5
  done
  warn "за 15 минут /health не ответил, хотя контейнер работает — смотри: sudo docker logs -f halogen"
}

# ── 6. Ollama ────────────────────────────────────────────────────────
do_ollama() {
  step "Ollama"
  have ollama || curl -fsSL https://ollama.com/install.sh | sh
  sudo usermod -aG render,video ollama 2>/dev/null || true
  local models_env=""
  if [[ -n "$OLLAMA_MODELS_DIR" ]]; then
    sudo mkdir -p "$OLLAMA_MODELS_DIR" && sudo chown ollama:ollama "$OLLAMA_MODELS_DIR"
    models_env="Environment=\"OLLAMA_MODELS=$OLLAMA_MODELS_DIR\""
  fi
  # Ollama на gfx1151 работает через ROCm (тот же KFD, что и halogen). GPU_MAX_HW_QUEUES=2: если у всех
  # процессов вместе больше 8 аппаратных очередей, iGPU в простое загружен на 100% (docs/host-setup.md).
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  sudo tee /etc/systemd/system/ollama.service.d/ai395.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=$OLLAMA_BIND"
$models_env
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_CONTEXT_LENGTH=$OLLAMA_CTX"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_KEEP_ALIVE=$OLLAMA_KEEP_ALIVE"
Environment="GPU_MAX_HW_QUEUES=2"
EOF
  sudo systemctl daemon-reload

  # halogen держит почти всю память, а Ollama меряет свободную по MemAvailable, который при работающем
  # halogen завышен на ~62 ГиБ: первая же модель подвесила бы halogen. Поэтому рядом с ним — без автозапуска.
  local autostart=$OLLAMA_AUTOSTART
  if [[ "$autostart" == auto ]]; then
    if [[ "$ENGINE" == halogen ]]; then autostart=0; else autostart=1; fi
  fi
  if ((autostart)); then
    sudo systemctl enable ollama
    sudo systemctl restart ollama
    sleep 3
    local m
    for m in $OLLAMA_PULL; do ollama pull "$m"; done
    ok "ollama: http://$OLLAMA_BIND  (модели: ${OLLAMA_MODELS_DIR:-/usr/share/ollama/.ollama/models})"
  else
    sudo systemctl disable --now ollama >/dev/null 2>&1 || true
    ok "ollama установлена, но сама не запускается: halogen занимает почти всю память"
    echo "   запустить:      sudo docker stop -t 60 halogen && sudo systemctl start ollama"
    echo "   вернуть halogen: sudo systemctl stop ollama && sudo docker start halogen"
  fi
}

# ── 7. PyTorch ROCm под gfx1151 ──────────────────────────────────────
do_pytorch() {
  step "PyTorch ROCm (gfx1151)"
  ensure_uv
  [[ -x "$TORCH_VENV/bin/python" ]] || uv venv -q --python "$TORCH_PYTHON" "$TORCH_VENV"
  if ! "$TORCH_VENV/bin/python" -c "import torch" 2>/dev/null; then
    uv pip install --python "$TORCH_VENV/bin/python" --index-url "$TORCH_INDEX" torch torchvision torchaudio
    uv pip install --python "$TORCH_VENV/bin/python" numpy transformers accelerate safetensors \
      huggingface_hub diffusers sentencepiece
  fi
  ok "активация: source $TORCH_VENV/bin/activate"
  # GPU-тест рядом с работающим halogen не гоняем: чужая работа на GPU мешает ему и может оставить GTT занятой
  if have docker && [[ "$(container_status)" == running ]]; then
    warn "halogen работает — GPU-тест PyTorch пропускаю. Проверить: sudo docker stop -t 60 halogen && ./setup-ai395.sh pytorch"
    return 0
  fi
  if ! id -nG | grep -qw render; then
    warn "текущая сессия ещё без группы render — проверка GPU после перелогина: ./setup-ai395.sh pytorch"
    return 0
  fi
  GPU_MAX_HW_QUEUES=2 "$TORCH_VENV/bin/python" - <<'EOF'
import time, torch
print("torch", torch.__version__, "| hip", torch.version.hip)
assert torch.cuda.is_available(), "GPU не виден torch — нужен перелогин (группы render/video)?"
print("устройство:", torch.cuda.get_device_name(0))
free, total = torch.cuda.mem_get_info()
print(f"память GPU: {free/2**30:.0f} из {total/2**30:.0f} ГиБ свободно")
a = torch.randn(8192, 8192, device="cuda", dtype=torch.bfloat16)
torch.cuda.synchronize(); t = time.time()
for _ in range(20): a @ a
torch.cuda.synchronize()
print(f"bf16 matmul: {20 * 2 * 8192**3 / (time.time() - t) / 1e12:.1f} TFLOPS")
EOF
}

# ── 8. проверка ──────────────────────────────────────────────────────
# Только печатает состояние, поэтому в подшелле без set -e/pipefail/ERR: ни одна проверка не должна
# обрывать остальные (rocminfo | grep -m1 под pipefail давал SIGPIPE и ложные «✗ ошибка»).
do_verify() (
  set +eE +o pipefail
  trap - ERR
  step "Проверка"
  echo "ядро: $(uname -r) | cmdline: $(grep -o 'ttm.pages_limit=[0-9]*' /proc/cmdline || echo 'ttm не задан — нужна перезагрузка')"
  local d
  for d in /sys/class/drm/card*/device; do
    [[ -f $d/mem_info_gtt_total ]] || continue
    echo "iGPU $(basename "$(dirname "$d")"): VRAM $(( $(cat "$d/mem_info_vram_total") / 1024**3 )) ГиБ, GTT $(( $(cat "$d/mem_info_gtt_total") / 1024**3 )) ГиБ (занято $(( $(cat "$d/mem_info_gtt_used") / 1024**3 )))"
  done
  echo "zswap: $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo нет) | swap: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
  if have vulkaninfo; then vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName" | sed 's/^ */vulkan: /'; fi

  local hst=""
  if have docker; then hst=$(container_status); fi
  if have rocminfo; then
    if [[ "$hst" == running ]]; then
      echo "rocm: пропускаю rocminfo, пока работает halogen"
    else
      local r; r=$(rocminfo 2>&1)
      if [[ $r == *gfx1151* ]]; then echo "rocm: gfx1151"
      else echo "rocm: gfx1151 не виден ($(grep -m1 -iE 'unable|not loaded|fail|denied' <<<"$r"))"; fi
    fi
  fi
  echo "группы: $(id -nG)"

  if have docker; then
    local st h
    st=$(sudo docker inspect -f '{{.State.Status}}, перезапусков {{.RestartCount}} {{.State.Error}}' halogen 2>/dev/null)
    if [[ -z "$st" ]]; then
      echo "halogen: контейнера нет — ./setup-ai395.sh halogen"
    else
      h=$(curl -s -m 5 http://127.0.0.1:8731/health) || h="не отвечает (веса ещё грузятся? sudo docker logs --tail 30 halogen)"
      echo "halogen: $st | /health: ${h:0:300}"
      if [[ "$hst" != running ]]; then echo "   запустить: sudo docker start halogen; лог: sudo docker logs --tail 50 halogen"; fi
    fi
  fi
  if systemctl is-active -q halo-coder; then
    echo "halo-coder: $(curl -sf -m 5 "http://127.0.0.1:$HC_PORT/v1/models" | jq -r '.data[].id' 2>/dev/null)"
  else
    echo "halo-coder: не запущен"
  fi
  if systemctl is-active -q ollama; then echo "ollama: $(ollama --version 2>/dev/null | tail -1)"
  elif have ollama; then echo "ollama: установлена, не запущена (sudo systemctl start ollama)"
  else echo "ollama: не установлена"; fi
  if [[ -x "$TORCH_VENV/bin/python" ]]; then
    if [[ "$hst" == running ]]; then
      echo "torch: $("$TORCH_VENV/bin/python" -c 'import torch; print(torch.__version__)' 2>/dev/null) (GPU не трогаю, пока работает halogen)"
    else
      echo "torch: $("$TORCH_VENV/bin/python" -c 'import torch; print(torch.__version__, "GPU:", torch.cuda.is_available())' 2>/dev/null)"
    fi
  fi
  if have docker; then echo "docker: $(docker --version)"; fi
  return 0
)

# ── main ─────────────────────────────────────────────────────────────
main() {
  local steps=("$@")
  if ((${#steps[@]} == 0)); then
    local engine_step=halogen; [[ "$ENGINE" == llama ]] && engine_step=halo-coder
    steps=(system nosleep docker llama models "$engine_step" ollama pytorch verify)
  fi
  preflight
  exec > >(tee -a "$LOG_DIR/setup-$(date +%F).log") 2>&1
  local s
  for s in "${steps[@]}"; do
    case "$s" in
      system) do_system ;; nosleep) "$SCRIPT_DIR/nosleep.sh" ;; docker) do_docker ;; llama) do_llama ;; models) do_models ;;
      halogen) do_halogen ;; halo-coder) do_halo_coder ;; ollama) do_ollama ;; pytorch) do_pytorch ;; verify) do_verify ;;
      *) die "неизвестный шаг «$s». Есть: system nosleep docker llama models halogen halo-coder ollama pytorch verify" ;;
    esac
  done
  # параметры ядра записаны, но ещё не действуют — напомним, даже если записал их прошлый запуск
  if [[ -f /etc/default/grub.d/90-ai395.cfg ]] && ! grep -q 'ttm.pages_limit=' /proc/cmdline; then REBOOT_NEEDED=1; fi
  if ((REBOOT_NEEDED)); then
    echo; warn "нужна перезагрузка (параметры ядра / группы): sudo reboot — halogen поднимется сам; потом ./setup-ai395.sh verify"
  fi
}
main "$@"
