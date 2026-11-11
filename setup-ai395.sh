#!/usr/bin/env bash
# Настройка AMD Ryzen AI Max+ 395 (Strix Halo, Radeon 8060S / gfx1151) под нейросети.
# Ubuntu 24.04+/26.04. Запускать обычным пользователем с sudo, НЕ от root.
#
#   ./setup-ai395.sh                 # всё по порядку
#   ./setup-ai395.sh models halogen  # отдельные шаги
#   ./setup-ai395.sh verify
#
# Шаги: system nosleep docker llama models halogen halo-coder ollama pytorch verify
# По умолчанию движок — halogen (ENGINE=halogen), halo-coder на llama.cpp — запасной (ENGINE=llama).
# Каждый шаг можно перезапускать: уже сделанное он пропустит.
set -euo pipefail

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
: "${HG_WEIGHTS_REPO:=peonist-ai/halogen-qwen3.8-flash-next}" "${HG_EXTRA_ENV:=}"
: "${LLAMA_REPO:=https://github.com/ggml-org/llama.cpp.git}" "${LLAMA_REF:=b11627}"
: "${MODEL_REPO:=mradermacher/Qwen3.8-Flash-Next-Uncensored-i1-GGUF}"
: "${MODEL_FILE:=Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf}"
: "${MTP:=1}" "${MTP_REPO:=ggml-org/Qwen3.8-Flash-Next-GGUF}" "${MTP_FILE:=mtp-Qwen3.8-Flash-Next-Q8_0.gguf}"
: "${MTP_REQUANT:=1}" "${QSA:=1}"
: "${HC_ALIAS:=qwen38-flash-next-unc}" "${HC_HOST:=127.0.0.1}" "${HC_PORT:=8088}"
: "${CTX:=262144}" "${SLOTS:=1}" "${CACHE_RAM_MIB:=2048}" "${UBATCH:=512}"
: "${DRAFT_N_MAX:=3}" "${DRAFT_P_MIN:=0.75}" "${WATCHDOG:=1}"
: "${OLLAMA_BIND:=127.0.0.1:11434}" "${OLLAMA_CTX:=131072}" "${OLLAMA_PULL:=}"
: "${TORCH_INDEX:=https://rocm.nightlies.amd.com/v2/gfx1151/}" "${TORCH_PYTHON:=3.12}"

BIN_DIR="$AI_HOME/bin"
TOOLS_VENV="$AI_HOME/venv-tools"
TORCH_VENV="$AI_HOME/venv-torch"
LOG_DIR="$AI_HOME/logs"
REBOOT_NEEDED=0

# ── утилиты ──────────────────────────────────────────────────────────
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_h=$'\e[1;36m'; c_0=$'\e[0m'
step() { echo; echo "${c_h}══ $* ══${c_0}"; }
ok()   { echo "${c_ok}✓${c_0} $*"; }
warn() { echo "${c_warn}!${c_0} $*"; }
die()  { echo "${c_err}✗ $*${c_0}" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  local missing=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# пакет, которого может не быть в этой версии Ubuntu — ставим, если есть
apt_try() { for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 && apt_install "$p" || warn "пакета $p нет в репозитории — пропускаю"; done; }

preflight() {
  [[ $EUID -ne 0 ]] || die "запускай обычным пользователем (sudo скрипт спросит сам)"
  [[ -r /etc/os-release ]] && . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || warn "скрипт писался под Ubuntu, а тут ${PRETTY_NAME:-неизвестно}"
  grep -q "AMD Ryzen AI MAX" /proc/cpuinfo || warn "это не Ryzen AI Max — параметры памяти могут не подойти"
  sudo -v || die "нужен sudo"
  mkdir -p "$AI_HOME" "$BIN_DIR" "$LOG_DIR"
}

ensure_uv() {
  have uv && return 0
  [[ -x "$HOME/.local/bin/uv" ]] || curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
}

ensure_tools_venv() {
  ensure_uv
  [[ -x "$TOOLS_VENV/bin/python" ]] || uv venv -q --python "$TORCH_PYTHON" "$TOOLS_VENV"
  uv pip install -q --python "$TOOLS_VENV/bin/python" "huggingface_hub[cli,hf_xet]" gguf numpy
}

mem_total_kb() { awk '/^MemTotal:/ {print $2}' /proc/meminfo; }

# ── 1. система: пакеты, драйвер, память iGPU, swap, группы ───────────
do_system() {
  step "Система"
  sudo apt-get update -q
  apt_install build-essential cmake ninja-build git git-lfs ccache pkg-config curl ca-certificates openssl \
              libcurl4-openssl-dev libssl-dev python3 python3-venv jq htop nvtop pciutils \
              mesa-vulkan-drivers vulkan-tools libvulkan-dev glslc spirv-headers \
              linux-firmware radeontop power-profiles-daemon
  apt_try rocminfo rocm-smi amdgpu-top

  # Группы для доступа к /dev/kfd и /dev/dri
  for g in render video; do
    if ! id -nG "$USER" | grep -qw "$g"; then sudo usermod -aG "$g" "$USER"; REBOOT_NEEDED=1; ok "добавлен в группу $g"; fi
  done

  # Память iGPU. На Strix Halo VRAM — это кусок ОЗУ. Всё, что не carveout из BIOS, iGPU берёт
  # динамически через GTT. Набор флагов — тот, на котором мерил halogen-flash-server
  # (docs/troubleshooting.md), размеры GTT считаются от ОЗУ этой машины, а не копируются.
  local total_kb pages params
  total_kb=$(mem_total_kb)
  pages=$(( total_kb / 4 ))
  params="amdgpu.vm_update_mode=0 amdgpu.noretry=0 amdgpu.sg_display=0"
  params+=" amdgpu.gttsize=$(( total_kb / 1024 )) ttm.pages_limit=$pages ttm.page_pool_size=$pages"
  if ((AMD_IOMMU_OFF)); then params+=" amd_iommu=off"; else params+=" iommu=pt"; fi
  ((DISABLE_ZSWAP)) && params+=" zswap.enabled=0"
  local cfg=/etc/default/grub.d/90-ai395.cfg
  local want="GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $params\""
  if [[ "$(cat "$cfg" 2>/dev/null)" != "$want" ]]; then
    sudo mkdir -p /etc/default/grub.d
    echo "$want" | sudo tee "$cfg" >/dev/null
    sudo update-grub
    REBOOT_NEEDED=1
    ok "параметры ядра: $params (GTT ≈ $(( pages * 4 / 1024 / 1024 )) ГиБ)"
  else
    ok "параметры ядра уже стоят"
  fi
  if ((DISABLE_ZSWAP)) && [[ -e /sys/module/zswap/parameters/enabled ]]; then
    echo N | sudo tee /sys/module/zswap/parameters/enabled >/dev/null   # и сразу, без перезагрузки
  fi

  # Carveout из BIOS: если он большой, эта память потеряна для GTT и для системы
  local vram
  vram=$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -n | tail -1 || echo 0)
  if (( vram > 4 * 1024 ** 3 )); then
    warn "в BIOS отдано под iGPU $(( vram / 1024 ** 3 )) ГиБ (UMA Frame Buffer Size)."
    warn "поставь 512M–2G: под Linux iGPU всё равно берёт память через GTT, а так вернёшь $(( vram / 1024 ** 3 - 2 ))+ ГиБ."
  fi

  # Страховочный swap: под почти полным контекстом пик памяти выше ОЗУ
  local swf=/swapfile-llm
  if ((SWAP_GB > 0)) && ! swapon --show=NAME --noheadings | grep -qx "$swf"; then
    if [[ ! -f $swf ]]; then
      if [[ "$(findmnt -no FSTYPE /)" == btrfs ]]; then
        sudo btrfs filesystem mkswapfile --size "${SWAP_GB}g" "$swf"   # fallocate на btrfs даёт «Invalid argument»
      else
        sudo fallocate -l "${SWAP_GB}G" "$swf" && sudo chmod 600 "$swf" && sudo mkswap "$swf" >/dev/null
      fi
    fi
    sudo swapon "$swf"
    grep -q "^$swf " /etc/fstab || echo "$swf none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab >/dev/null
    ok "swap $swf ${SWAP_GB} ГБ"
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
    powerprofilesctl set performance 2>/dev/null && ok "профиль питания: performance" || warn "не удалось включить performance"
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
  sudo systemctl enable --now docker
  if ! id -nG "$USER" | grep -qw docker; then sudo usermod -aG docker "$USER"; REBOOT_NEEDED=1; fi

  # Обёртка: контейнер с доступом к iGPU (ROCm через /dev/kfd, Vulkan через /dev/dri)
  cat > "$BIN_DIR/docker-gpu" <<'EOF'
#!/usr/bin/env bash
# docker-gpu <образ> [команда] — docker run с проброшенным iGPU Strix Halo
exec docker run --rm -it \
  --device /dev/kfd --device /dev/dri \
  --group-add video --group-add render \
  --security-opt seccomp=unconfined --ipc=host \
  -e HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-}" \
  -v "$HOME/models:/models" "$@"
EOF
  chmod +x "$BIN_DIR/docker-gpu"
  ok "docker готов; GPU в контейнер: $BIN_DIR/docker-gpu <образ> (нужен перелогин для группы docker)"
}

# ── 3. llama.cpp (Vulkan, статически) ────────────────────────────────
do_llama() {
  step "llama.cpp $LLAMA_REF (Vulkan)"
  local src="$AI_HOME/src/llama.cpp" dst="$BIN_DIR/llama-$LLAMA_REF"
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
  "$BIN_DIR/llama-current/llama-server" --list-devices 2>&1 | grep -E "Vulkan|Radeon" \
    || warn "llama-server не видит Vulkan-устройство — проверь группу render и mesa"
}

# ── 4. Веса Qwen3.8-Flash-Next (без цензуры) + MTP ───────────────────
model_path() { local f="$MODEL_DIR/$MODEL_FILE"; ((QSA)) && f="${f%.gguf}.qsa.gguf"; echo "$f"; }
mtp_path()   { local f="$MODEL_DIR/$MTP_FILE"; ((MTP_REQUANT)) && f="${f%.gguf}-output-q5_k.gguf"; echo "$f"; }

do_models() {
  step "Модели"
  ensure_tools_venv
  mkdir -p "$MODEL_DIR"
  local avail_gb
  avail_gb=$(df -BG --output=avail "$MODEL_DIR" | tail -1 | tr -dc 0-9)
  (( avail_gb > 120 )) || warn "на $MODEL_DIR свободно ${avail_gb} ГБ — может не хватить (модель + QSA-копия на не-btrfs)"

  local hf="$TOOLS_VENV/bin/hf"
  if [[ ! -f "$MODEL_DIR/$MODEL_FILE" ]]; then
    echo "качаю $MODEL_REPO/$MODEL_FILE (десятки ГБ, можно прервать и перезапустить — докачает)"
    "$hf" download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
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
    [[ -f "$MODEL_DIR/$MTP_FILE" ]] || "$hf" download "$MTP_REPO" "$MTP_FILE" --local-dir "$MODEL_DIR"
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
    warn "останавливаю halogen: вдвоём с halo-coder память не поделят"
    sudo docker update --restart=no halogen >/dev/null; sudo docker stop halogen >/dev/null || true
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
  has '--flash-attn' && args+=(-fa on)
  has '--cache-ram'  && args+=(--cache-ram "$CACHE_RAM_MIB")

  if ((MTP)); then
    local mtp; mtp=$(mtp_path)
    has '--spec-type' && args+=(--spec-type draft-mtp)
    args+=(-md "$mtp" -ngld 999)
    if has '--spec-draft-n-max'; then
      args+=(--spec-draft-n-max "$DRAFT_N_MAX" --spec-draft-p-min "$DRAFT_P_MIN")
    else
      args+=(--draft-max "$DRAFT_N_MAX" --draft-p-min "$DRAFT_P_MIN")
    fi
    has '-ctkd' && args+=(-ctkd q8_0 -ctvd q8_0)   # иначе KV драфта в f16
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

# ── 5a. halogen-flash-server на Uncensored GGUF ──────────────────────
do_halogen() {
  step "halogen-flash-server ($HG_IMAGE)"
  have docker || do_docker
  [[ -f "$MODEL_DIR/$MODEL_FILE" ]] || do_models

  if systemctl is-enabled -q halo-coder 2>/dev/null; then
    warn "выключаю halo-coder: вдвоём с halogen память не поделят"
    sudo systemctl disable --now halo-coder halo-coder-watchdog.timer 2>/dev/null || true
  fi

  # Ядро: нужны фиксы KFD под gfx1151 и CONFIG_HSA_AMD_SVM (иначе регистрация весов отказывает)
  local node props cap
  for node in /sys/class/kfd/kfd/topology/nodes/*; do
    grep -q 'gfx_target_version 110501' "$node/properties" 2>/dev/null || continue
    props="$node/properties"
  done
  if [[ -n "${props:-}" ]]; then
    cap=$(awk '$1=="capability"{print $2}' "$props")
    (( cap & 0x08000000 )) && ok "ядро: KFD SVM есть" || warn "ядро собрано без CONFIG_HSA_AMD_SVM — halogen не загрузит веса"
    grep -q '^cwsr_size' "$props" && ok "ядро: фиксы gfx1151 есть" || warn "в ядре нет фиксов KFD для gfx1151 (нужно ≥ 6.18.4 / Ubuntu 7.0)"
  else
    warn "KFD-узел gfx1151 не найден — проверь /dev/kfd и группу render"
  fi

  local env_args=(
    -e "HALOGEN_CHECKPOINT=/models/$MODEL_FILE"
    -e "HALOGEN_DOWNLOAD=$HG_WEIGHTS_REPO"     # только драфт-голова и токенайзер, GGUF не качает
  )
  if ((HG_API_KEY)); then
    local keyf="$AI_HOME/halogen.key"
    [[ -s "$keyf" ]] || { (umask 077; openssl rand -hex 24 >"$keyf"); }
    chmod 644 "$keyf"   # контейнер читает его своим пользователем
    env_args+=(-e HALOGEN_API_KEY_FILE=/run/halogen.key -v "$keyf:/run/halogen.key:ro")
  fi
  local kv
  for kv in $HG_EXTRA_ENV; do env_args+=(-e "$kv"); done

  sudo docker pull -q "$HG_IMAGE"
  sudo docker rm -f halogen >/dev/null 2>&1 || true
  # Том моделей rw: первый старт докладывает в него драфт-голову (qwen38-flash-next-mtp.hgn)
  sudo docker run -d --name halogen --restart unless-stopped \
    -p "$HG_PUBLISH:8731" \
    --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    --ipc=host --ulimit memlock=-1:-1 \
    "${env_args[@]}" \
    -v "$MODEL_DIR:/models" \
    "$HG_IMAGE" >/dev/null

  echo "жду готовности (первый старт качает 1.4 ГиБ и переупаковывает GGUF, до 10 минут)…"
  local i
  for i in $(seq 1 120); do
    if curl -sf -m 5 http://127.0.0.1:8731/health >/dev/null; then
      ok "halogen готов: http://$(hostname -I | awk '{print $1}'):8731/v1 (OpenAI) и /v1/messages (Anthropic)"
      ((HG_API_KEY)) && ok "API-ключ: $AI_HOME/halogen.key"
      sudo docker logs halogen 2>&1 | grep -m2 'host memory left\|checkpoint_format' || true
      return 0
    fi
    [[ "$(sudo docker inspect -f '{{.State.Running}}' halogen 2>/dev/null)" == true ]] \
      || { sudo docker logs --tail 40 halogen; die "halogen упал при старте"; }
    sleep 5
  done
  warn "за 10 минут не поднялся — смотри: sudo docker logs -f halogen"
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
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  sudo tee /etc/systemd/system/ollama.service.d/ai395.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=$OLLAMA_BIND"
$models_env
Environment="OLLAMA_VULKAN=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_CONTEXT_LENGTH=$OLLAMA_CTX"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_KEEP_ALIVE=5m"
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable ollama
  sudo systemctl restart ollama
  sleep 3
  local m
  for m in $OLLAMA_PULL; do ollama pull "$m"; done
  ok "ollama: http://$OLLAMA_BIND  (модели: ${OLLAMA_MODELS_DIR:-/usr/share/ollama/.ollama/models})"
  warn "halogen/halo-coder занимают ~90 ГБ: в ollama параллельно — только небольшие модели."
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
  if ! id -nG | grep -qw render; then
    warn "текущая сессия ещё без группы render — проверка GPU после перелогина: ./setup-ai395.sh pytorch"
    return 0
  fi
  "$TORCH_VENV/bin/python" - <<'EOF'
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
  ok "активация: source $TORCH_VENV/bin/activate"
}

# ── 8. проверка ──────────────────────────────────────────────────────
do_verify() {
  step "Проверка"
  echo "ядро: $(uname -r) | cmdline: $(grep -o 'ttm.pages_limit=[0-9]*' /proc/cmdline || echo 'ttm не задан — нужна перезагрузка')"
  local d
  for d in /sys/class/drm/card*/device; do
    [[ -f $d/mem_info_gtt_total ]] || continue
    echo "iGPU $(basename "$(dirname "$d")"): VRAM $(( $(cat "$d/mem_info_vram_total") / 1024**3 )) ГиБ, GTT $(( $(cat "$d/mem_info_gtt_total") / 1024**3 )) ГиБ (занято $(( $(cat "$d/mem_info_gtt_used") / 1024**3 )))"
  done
  echo "zswap: $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo нет) | swap: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
  have vulkaninfo && vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName" | sed 's/^ */vulkan: /'
  have rocminfo && rocminfo 2>/dev/null | grep -m1 -o "gfx1151" | sed 's/^/rocm: /'
  echo "группы: $(id -nG)"
  if have docker && [[ "$(sudo docker inspect -f '{{.State.Running}}' halogen 2>/dev/null)" == true ]]; then
    echo "halogen: $(curl -s -m 5 http://127.0.0.1:8731/health | head -c 300)"
  else
    echo "halogen: не запущен"
  fi
  systemctl is-active -q halo-coder && curl -sf -m 5 "http://127.0.0.1:$HC_PORT/v1/models" | jq -r '.data[].id' | sed 's/^/halo-coder: /' || echo "halo-coder: не запущен"
  systemctl is-active -q ollama && echo "ollama: $(ollama --version 2>/dev/null | tail -1)" || echo "ollama: не запущен"
  [[ -x "$TORCH_VENV/bin/python" ]] && "$TORCH_VENV/bin/python" -c "import torch;print('torch:', torch.__version__, torch.cuda.is_available())" 2>/dev/null || true
  have docker && echo "docker: $(docker --version)"
}

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
  if ((REBOOT_NEEDED)); then
    echo; warn "нужна перезагрузка (параметры ядра / группы): sudo reboot, потом ./setup-ai395.sh verify"
  fi
}
main "$@"
