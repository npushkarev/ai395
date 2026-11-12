# ai395

Настройка мини-ПК на **AMD Ryzen AI Max+ 395** (Strix Halo, Radeon 8060S / gfx1151, 128 ГБ) под нейросети на Ubuntu 24.04+/26.04.

## Что ставит

| Шаг | Что делает |
|---|---|
| `system` | Почти всё ОЗУ отдаётся iGPU через GTT (`ttm.pages_limit`), `amd_iommu=off`, zswap выключен, swap 32 ГБ, Vulkan (Mesa RADV), tmux, группы render/video, профиль питания performance |
| `nosleep` | ПК не засыпает: сон замаскирован в systemd, logind и GNOME не усыпляют по простою (`./nosleep.sh --undo` — вернуть) |
| `docker` | Docker (ждёт `/dev/kfd` при загрузке) + обёртка `docker-gpu`; заранее тянет образ halogen |
| `llama` | llama.cpp, статическая сборка с Vulkan |
| `models` | по умолчанию — быстрый чекпоинт halogen v2 (~112 ГиБ); при `HG_MODEL=uncensored` — Qwen3.8-Flash-Next-Uncensored i1-IQ4_XS |
| `halogen` | **движок по умолчанию.** [halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) в Docker: OpenAI + Anthropic API на `:8731`, API-ключ, картинки, сам поднимается после перезагрузки |
| `halo-coder` | запасной движок: llama-server как systemd-служба (`127.0.0.1:8088`), автоперезапуск, защита от OOM-killer, сторож зависаний |
| `ollama` | Ollama (ROCm), KV q8_0, flash attention. При `ENGINE=halogen` сама не запускается — см. ниже |
| `pytorch` | PyTorch ROCm под gfx1151 (колёса AMD TheRock) + тест умножения матриц (пропускается, пока работает halogen) |
| `verify` | Сводка: GTT, Vulkan, ROCm, halogen, службы |

## Запуск

```bash
git clone https://github.com/npushkarev/ai395 ~/ai395-src && cd ~/ai395-src
tmux new -s ai395          # загрузка моделей идёт часами — в tmux она переживёт закрытие окна
./setup-ai395.sh           # всё по порядку (обычным пользователем, sudo спросит пароль один раз)
sudo reboot                # параметры ядра; halogen после перезагрузки поднимется сам
cd ~/ai395-src && ./setup-ai395.sh verify
```

- Не клонируйте прямо в `~/ai395`: это рабочий каталог скрипта (бинарники, логи, ключ API).
- Шаги можно запускать по одному: `./setup-ai395.sh models halogen`. Повторный запуск пропускает уже сделанное
  и не перезапускает halogen, если его настройки не менялись.
- Загрузку можно прервать (Ctrl+C, обрыв сети, закрытое окно) — повторный запуск докачает с того же места.
- Если вышли из tmux: `tmux attach -t ai395`. Сколько осталось — из любого терминала: `./halogen-fast.sh progress`.

## Движок

`ENGINE=halogen` (по умолчанию) или `ENGINE=llama` в `ai395.conf`. Одновременно оба не работают:
halogen забирает почти всю память. Шаги `halogen` и `halo-coder` сами выключают друг друга.

halogen открывает и GGUF без конвертации; mradermacher `i1-IQ4_XS` у них измерен (68 ГиБ в памяти, ~36 т/с
с драфт-головой). Драфт-голова у halogen своя, обучена на базовой модели — на Uncensored может приниматься
чуть реже.

### Модель: быстрая (по умолчанию) или без цензуры

```bash
./halogen-fast.sh             # скачать собственный чекпоинт halogen v2 (~112 ГиБ) и переключиться на него
./halogen-fast.sh uncensored  # переключиться на Uncensored GGUF (скачает ~91 ГБ, если его нет)
./halogen-fast.sh fast        # снова на быструю
./halogen-fast.sh status
./halogen-fast.sh progress    # сколько осталось докачать — можно из другого терминала
```

Во время любой загрузки модели раз в 20 с печатается строка вида
`⏬ скачано 23.4 из 112.1 ГиБ (20.9%) · 85.0 МБ/с · осталось ~17 мин`.

| | Uncensored GGUF | v2 (быстрая) |
|---|---|---|
| генерация | ~30–36 т/с | ~54 проза / ~73 код |
| промпт | ~1 250–1 420 т/с | ~1 700–1 800 т/с |
| цензура | нет | есть |

Цифры — из документации halogen, не замер на этом боксе.

## BIOS

- `UMA Frame Buffer Size` = **512M** (минимальное явное значение, не Auto). Под Linux iGPU берёт память
  динамически через GTT, а большой carveout просто отнимает ОЗУ у системы.
- Режим питания — максимальный (Performance / наибольший TDP): halogen мерили при ~85 Вт.

## Настройки

Всё в `ai395.conf`. Любую переменную можно переопределить из окружения:

```bash
HG_PUBLISH=127.0.0.1:8731 ./setup-ai395.sh halogen   # halogen только локально, без LAN
CTX=131072 ./setup-ai395.sh halo-coder               # меньше контекст, если упирается в память
```

## Управление

```bash
# halogen
sudo docker logs -f halogen
sudo docker restart halogen          # штатная остановка до 60 с — не убивает движок посреди работы
curl -H "Authorization: Bearer $(cat ~/ai395/halogen.key)" http://<ip>:8731/v1/models

# Ollama рядом с halogen: halogen держит почти всю память, поэтому по очереди
sudo docker stop -t 60 halogen && sudo systemctl start ollama
sudo systemctl stop ollama && sudo docker start halogen

# halo-coder (ENGINE=llama)
sudo systemctl status|restart|stop halo-coder
tail -f ~/ai395/logs/halo-coder.log
```

Не останавливайте halogen через `docker kill` / `docker rm -f`: движок, убитый посреди работы на GPU, может
оставить занятыми 35–45 ГиБ GTT, и тогда до перезагрузки он не стартует.
