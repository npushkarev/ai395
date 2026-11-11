# ai395

Настройка мини-ПК на **AMD Ryzen AI Max+ 395** (Strix Halo, Radeon 8060S / gfx1151, 128 ГБ) под нейросети на Ubuntu 24.04+/26.04.

## Что ставит

| Шаг | Что делает |
|---|---|
| `system` | Почти всё ОЗУ отдаётся iGPU через GTT (`ttm.pages_limit`), zswap выключен, swap 32 ГБ, Vulkan (Mesa RADV), группы render/video, профиль питания performance |
| `nosleep` | ПК не засыпает: сон замаскирован в systemd, logind и GNOME не усыпляют по простою (`./nosleep.sh --undo` — вернуть) |
| `docker` | Docker + обёртка `docker-gpu` (контейнер с `/dev/kfd` и `/dev/dri`) |
| `llama` | llama.cpp, статическая сборка с Vulkan |
| `models` | по умолчанию — быстрый чекпоинт halogen v2 (~111 ГиБ); при `HG_MODEL=uncensored` — Qwen3.8-Flash-Next-Uncensored i1-IQ4_XS |
| `halogen` | **движок по умолчанию.** [halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) в Docker на Uncensored GGUF: OpenAI + Anthropic API на `:8731`, API-ключ |
| `halo-coder` | запасной движок: llama-server как systemd-служба (`127.0.0.1:8088`), автоперезапуск, защита от OOM-killer, сторож зависаний |
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

## Движок

`ENGINE=halogen` (по умолчанию) или `ENGINE=llama` в `ai395.conf`. Одновременно оба не работают:
halogen забирает почти всю память. Шаги `halogen` и `halo-coder` сами выключают друг друга.

halogen открывает GGUF без конвертации; mradermacher `i1-IQ4_XS` у них измерен (68 ГиБ в памяти, ~36 т/с
с драфт-головой). Драфт-голова у halogen своя, обучена на базовой модели — на Uncensored принимается
может чуть реже.

### Модель: быстрая (по умолчанию) или без цензуры

```bash
./halogen-fast.sh             # скачать собственный чекпоинт halogen v2 (~111 ГиБ) и переключиться на него
./halogen-fast.sh uncensored  # обратно на Uncensored GGUF
./halogen-fast.sh fast        # снова на быструю
./halogen-fast.sh status
```

| | Uncensored GGUF | v2 (быстрая) |
|---|---|---|
| генерация | ~30–36 т/с | ~54 проза / ~73 код |
| промпт | ~1 250–1 420 т/с | ~1 700–1 800 т/с |
| цензура | нет | есть |

Цифры — из документации halogen, не замер на этом боксе.

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
# halogen
sudo docker logs -f halogen
sudo docker restart halogen
curl -H "Authorization: Bearer $(cat ~/ai395/halogen.key)" http://<ip>:8731/v1/models

# halo-coder (ENGINE=llama)
sudo systemctl status|restart|stop halo-coder
tail -f ~/ai395/logs/halo-coder.log
```

Движок занимает ~90 ГБ, поэтому в Ollama параллельно — только небольшие модели.
