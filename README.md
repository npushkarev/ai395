# ai395

Настройка мини-ПК на **AMD Ryzen AI Max+ 395** (Strix Halo, Radeon 8060S / gfx1151, 128 ГБ) под нейросети на Ubuntu 24.04+/26.04.

## Что ставит

| Шаг | Что делает |
|---|---|
| `system` | Почти всё ОЗУ отдаётся iGPU через GTT (`ttm.pages_limit`), zswap выключен, swap 32 ГБ, Vulkan (Mesa RADV), группы render/video, профиль питания performance |
| `docker` | Docker + обёртка `docker-gpu` (контейнер с `/dev/kfd` и `/dev/dri`) |
| `llama` | llama.cpp, статическая сборка с Vulkan |
| `models` | Qwen3.8-Flash-Next-Uncensored i1-IQ4_XS + MTP-голова, патч QSA на копии весов |
| `halo-coder` | llama-server как systemd-служба (OpenAI API на `127.0.0.1:8088`), автоперезапуск, защита от OOM-killer, сторож зависаний |
| `ollama` | Ollama через Vulkan, KV q8_0, flash attention |
| `pytorch` | PyTorch ROCm под gfx1151 (колёса AMD TheRock) + тест умножения матриц |
| `verify` | Сводка: GTT, Vulkan, ROCm, службы |

## Запуск

```bash
git clone https://github.com/npushkarev/ai395 && cd ai395
./setup-ai395.sh          # всё по порядку (обычным пользователем, sudo спросит сам)
sudo reboot
./setup-ai395.sh verify
```

Шаги можно запускать по одному: `./setup-ai395.sh llama halo-coder`. Повторный запуск пропускает уже сделанное.

## BIOS

`UMA Frame Buffer Size` = **512M** (максимум 2G). Под Linux iGPU берёт память динамически через GTT, а большой carveout просто отнимает ОЗУ у системы.

## Настройки

Всё в `ai395.conf`. Любую переменную можно переопределить из окружения:

```bash
CTX=131072 ./setup-ai395.sh halo-coder     # меньше контекст, если упирается в память
HC_HOST=0.0.0.0 ./setup-ai395.sh halo-coder # открыть сервер в LAN
```

## Управление

```bash
sudo systemctl status|restart|stop halo-coder
tail -f ~/ai395/logs/halo-coder.log
journalctl -t halo-coder-watchdog
```

halo-coder занимает ~90 ГБ, поэтому крупные модели в Ollama одновременно с ним не влезут.
