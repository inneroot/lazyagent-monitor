# Lazyagent Monitor — плагин Noctalia v5

Показывает в баре Noctalia активность запущенных LLM-агентов (`pi`, `opencode`,
`claude` и др.) через HTTP API локального сервиса
[lazyagent](https://lazyagent.dev): компактный счётчик `активных/всего`
(зелёный, если есть активность) и разбивку по агентам в tooltip.

## Состав

```
lazyagent-monitor/
  plugin.toml          # манифест: [[widget]] monitor + [[desktop_widget]] desktop + [[service]] bridge
  service.luau         # SSE-клиент: подключение, парсинг, дедупликация, переподключение
  widget.luau          # бар-виджет: глиф + цвет + tooltip
  desktop_widget.luau  # desktop-виджет: глиф + цвет + inline-разбивка
  translations/        # подписи настроек и строк (10 языков: en ru de fr es it pt zh ja hi)
```

Сервис и виджеты работают в изолированных VM и обмениваются данными только
через `noctalia.state` (ключи `snapshot` и `status`).

Индикация — цветом и глифом, текст используется по минимуму:

| Состояние | Глиф | Цвет |
|-----------|------|------|
| Есть активные агенты | `activity` | зелёный `#22c55e` |
| Подключены, активных нет | `circle` | серый `#8a8f98` |
| Нет данных | `circle` | серый `#8a8f98` |
| Поток разорван | `alert-circle` | янтарный `#d97706` |

## Установка

### Из локального репозитория (разработка)

1. Добавьте path-источник в конфиг Noctalia
   (`~/.config/noctalia/config.toml` или через Settings → Plugins → Sources):

   ```toml
   [plugins]
     [[plugins.source]]
     enabled = true
     kind = "path"
     name = "inner"
     location = "/home/inner/dev/lazyagent-monitor"
   ```

   > Директория-источник должна содержать **подпапку** с плагином
   > (`lazyagent-monitor/plugin.toml`), как в репозиториях community/official.

2. Включите плагин: `noctalia msg plugins enable inner/lazyagent-monitor`
   или Settings → Plugins.

3. Добавьте виджет в бар — в конфиге:

   ```toml
   [widget.lazyagent_monitor]
   type = "inner/lazyagent-monitor:monitor"
   ```

   и вставьте `"lazyagent_monitor"` в список `start`/`end` нужного бара.

4. **Desktop-виджет** (опционально): добавьте его в редакторе desktop-виджетов
   (`Settings → Desktop widgets → Add → `inner/lazyagent-monitor:desktop``).
   Позицию и размер задаёте вручную (хост-owned); скрипт рисует только контент.

### Из community-каталога

Плагин появится в каталоге после публикации в
`noctalia-dev/community-plugins`.

## Зависимости

- Noctalia v5 (plugin_api ≥ 24; `httpStream` требует ≥ 4, `nowMs()` — ≥ 12,
  argv-формат `runAsync` — ≥ 24)
- `lazyagent` с запущенным API: `lazyagent --api`
  (по умолчанию `http://127.0.0.1:7421`)

## Настройки

| Настройка | По умолчанию | Описание |
|-----------|--------------|----------|
| `token` | пусто | Bearer-токен lazyagent. Пустое значение — выводится автоматически через `lazyagent passphrase --show`. |
| `lazyagent_bin` | `lazyagent` | Имя или полный путь к бинарнику, видимый из процесса Noctalia (его PATH отличается от PATH вашей shell). |
| `language` (виджет и desktop) | `auto` | Язык отображения. `auto` — как в системе; иначе код из `en ru de fr es it pt zh ja hi`. |

> Настройка `language` — на уровне виджета (`[[widget.setting]]`) и
> desktop-виджета (`[[desktop_widget.setting]]`): Settings бара → виджет
> `lazyagent_monitor` (или Settings → Desktop widgets). «Auto» следует языку
> shell; выбранный язык читается напрямую из `translations/<lang>.json`.

## Как это работает

1. Сервис разрешает токен (настройка → `lazyagent passphrase --show` →
   `bearer_token` в `config.json`) и открывает SSE-поток
   `GET /api/events?token=...` (для SSE токен передаётся только query-параметром).
2. Каждое событие `data: {json}` парсится; «отпечаток» состояния
   (`session_id:activity:is_active:short_name` по каждой сессии + `stats`)
   сравнивается с предыдущим — heartbeat'ы без изменений **не публикуются**,
   виджет не перерисовывается.
3. При разрыве (`onClose`) сервис переподключается через 5 секунд; при 401 —
   сбрасывает кэш токена, показывает уведомление и повторяется с интервалом 30 с.

## Запуск `lazyagent --api` из виджета

**Правый клик** по виджету переключает локальный сервер `lazyagent --api`:

- когда процесс не запущен — запускает его (виджет: `checking… → starting…`),
  после чего сервис сам подключается (≤ 5 с) и возвращает `active/total`;
- когда процесс запущен — останавливает его (`stopping…`), виджет уходит в `?`.

- Бинарник берётся из настройки `lazyagent_bin` (решает проблему PATH — см.
  траблшутинг); по умолчанию `lazyagent`.
- Определение «запущен/остановлен» идёт через `noctalia.processMatches`;
  старт игнорируется при `status = "connected"` (защита от дублей).
- Если бинарник не найден на PATH — плагин показывает уведомление
  «Binary not found» и просит задать `lazyagent_bin` полным путём.
- После запуска виджет ~8 с не переключается в `?` (grace-period), чтобы
  `starting…` не мерцал, пока сервер поднимается.

## Траблшутинг

- **Виджет показывает `?`** — поток разорван, сервис переподключается.
- **Уведомление о 401** — passphrase lazyagent сменён: очистите настройку
  `token` (или обновите её) — сервис сам перевычислит токен.
- **`token resolution failed` в логах** — `lazyagent` не найден: укажите
  полный путь в `lazyagent_bin` (PATH процесса Noctalia не содержит
  `~/go/bin`).
- **`failed to execute 'lazyagent'` / клик: `starting… → ?`** — бинарник
  `lazyagent` не виден процессу Noctalia. Задайте в настройках плагина
  `lazyagent_bin = /home/inner/go/bin/lazyagent` (или текущий путь из
  `command -v lazyagent`).
- Логи: `~/.cache/noctalia/noctalia.log`, тег `[script-runtime]`, префикс
  `lazyagent-monitor:`.
