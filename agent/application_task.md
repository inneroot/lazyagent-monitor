# Задание для coding agent: Плагин Noctalia для отображения LLM-агентов через lazyagent API

## 1. Обзор задачи

Разработать плагин для Noctalia Shell (v5+), который отображает информацию о запущенных LLM-агентах (pi, opencode и других) через HTTP API сервиса lazyagent. Плагин состоит из двух частей: фонового сервиса, который подключается к SSE-потоку lazyagent и публикует данные в общее состояние плагина, и бар-виджета, который отображает агрегированную статистику.

**Целевая среда**: Debian GNU/Linux 13 (trixie), WM niri (Wayland), Noctalia Shell v5+.

---

## 2. Архитектура решения

Плагин использует паттерн «service + widget», рекомендованный документацией Noctalia:

| Компонент | Назначение |
|-----------|------------|
| `[[service]]` | Подключается к SSE-потоку `/api/events`, парсит события, дедуплицирует и публикует состояние |
| `[[widget]]` | Читает состояние через `noctalia.state.watch()`, отображает агрегаты в баре |

Разделение обязательно: сервисы и виджеты выполняются в изолированных VM и не разделяют память Lua — обмен только через `noctalia.state`.

---

## 3. Источник данных: lazyagent HTTP API

### 3.1 Запуск сервера

Сервер уже запущен пользователем: `lazyagent --api` на `http://127.0.0.1:7421`. Аутентификация через Bearer token, который выводится при первом запуске и сохраняется в `~/.config/lazyagent/config.json`.

### 3.2 SSE-эндпоинт

**URL**: `GET /api/events`

**Особенность аутентификации для SSE**: заголовок `Authorization: Bearer` **не поддерживается** браузерными EventSource-клиентами, поэтому lazyagent принимает токен через query-параметр `?token=<token>` **только для этого эндпоинта**.

**Формат потока** (проверен в реальном терминале пользователя):
```
event: update
data: {"sessions":[...],"stats":{"total_sessions":1,"active_sessions":0,"window_minutes":30}}

event: update
data: {...}
```

Сервер отправляет полный снимок состояния регулярно (heartbeat), даже если ничего не изменилось.

### 3.3 Схема данных

**Каждая сессия в массиве `sessions`**:

| Поле | Тип | Описание |
|------|-----|----------|
| `session_id` | string | Уникальный идентификатор сессии |
| `agent` | string | Имя агента (`pi`, `opencode`, `claude`, и др.) |
| `cwd` | string | Рабочая директория проекта |
| `short_name` | string | Короткое имя (обычно путь) |
| `activity` | string | Состояние: `idle`, `thinking`, `writing`, `running`, `waiting` и др. |
| `is_active` | boolean | `true` если сессия активна прямо сейчас |
| `model` | string | Использованная модель |
| `cost_usd` | number | Оценка стоимости в долларах |
| `last_activity` | string | ISO 8601 timestamp последней активности |
| `total_messages` | number | Количество сообщений |

**Блок `stats`**:

| Поле | Тип | Описание |
|------|-----|----------|
| `total_sessions` | number | Всего сессий в окне |
| `active_sessions` | number | Активных сессий |
| `window_minutes` | number | Размер временного окна (по умолчанию 30 минут) |

---

## 4. Требования к реализации

### 4.1 Manifest (`plugin.toml`)

Обязательные поля: `id`, `name`, `version`, `plugin_api`.

**Минимальный `plugin_api`**: 4 (для `noctalia.httpStream()`).

**Структура**:
```toml
id = "<author>/lazyagent-monitor"
name = "Lazyagent Monitor"
version = "1.0.0"
plugin_api = 4
author = "<author>"
license = "MIT"
description = "Displays LLM agent activity from lazyagent API"

[[widget]]
id = "monitor"
entry = "widget.luau"

[[service]]
id = "bridge"
entry = "service.luau"
```

### 4.2 Сервис (`service.luau`)

**Задачи**:

1. **Чтение конфигурации**: Токен lazyagent хранится в `~/.config/lazyagent/config.json` (поле `bearer_token` или вычисляется из passphrase — уточнить в реальном файле). Читать через `noctalia.readFile()`.

2. **Подключение к SSE**: Использовать `noctalia.httpStream(request, onLine, onClose)`.

   **Критически важно**: lazyagent принимает токен для SSE через `?token=` query-параметр, потому что EventSource не поддерживает кастомные заголовки. Формат URL:
   ```
   http://127.0.0.1:7421/api/events?token=<bearer_token>
   ```

3. **Парсинг потока**: Каждая значимая строка имеет формат `data: {json}`. Строки `event: update` игнорировать. Парсить JSON через `noctalia.json.decode()`.

4. **Дедупликация (вариант А)**: Вычислять «отпечаток» состояния из ключевых полей (`session_id:activity:is_active` для каждой сессии + `stats.total_sessions:stats.active_sessions`). Сравнивать с предыдущим. Если совпадает — **не публиковать**, не обновлять состояние. Это предотвращает лишние перерисовки виджета при heartbeat-событиях.

5. **Публикация состояния**: Через `noctalia.state.set(key, value)`. Ключ, например, `"snapshot"`. Значение — таблица с полями:
   - `sessions`: массив сессий (только нужные поля для экономии)
   - `stats`: `{total, active, window_minutes}`
   - `agents`: агрегированный счётчик по агентам `{pi = N, opencode = M, ...}`

6. **Переподключение**: При `onClose` (разрыв соединения, ошибка 401) — переподключаться через `noctalia.setTimeout()` с задержкой 5 секунд. `httpStream` не переподключается автоматически.

### 4.3 Виджет (`widget.luau`)

**Задачи**:

1. **Подписка на состояние**: `noctalia.state.watch("snapshot", callback)`.

2. **Отображение в баре**: Использовать `barWidget.setText()` и/или `barWidget.setGlyph()`. Рекомендуемый формат — компактный, например: `● 2/5` (активных/всего) или иконка + число активных.

3. **Цветовая индикация** (опционально, если API поддерживает цвет текста): зелёный при `active > 0`, серый при `active == 0`.

4. **Tooltip**: При наведении показывать разбивку по агентам: «pi: 1 active, opencode: 0 active».

5. **Обработка пустого состояния**: Пока сервис не опубликовал первый снимок, показывать `—` или `0`.

---

## 5. Ограничения и известные проблемы

| Проблема | Решение |
|----------|---------|
| `httpStream` в Noctalia v5 использует нативный HTTP-клиент, но lazyagent требует токен для SSE через query-параметр | Использовать `?token=` в URL для SSE, как документировано в lazyagent |
| Токен может измениться при перезапуске lazyagent с новой passphrase | Читать `config.json` при каждом переподключении |
| Сервис и виджет — разные VM | Только `noctalia.state` для обмена данными |
| `onClose` вызывается при любой ошибке, включая 401 | При status=401 уведомить пользователя о необходимости проверить токен |

---

## 6. Критерии приёмки

- [ ] Плагин появляется в `Settings → Plugins` после установки в `~/.local/share/noctalia/plugins/`
- [ ] Сервис подключается к `http://127.0.0.1:7421/api/events?token=...` и получает события
- [ ] Дедупликация работает: виджет не перерисовывается при неизменных данных
- [ ] Виджет отображает `active/total` в баре
- [ ] Tooltip показывает разбивку по агентам
- [ ] При остановке lazyagent сервис переподключается через 5 секунд
- [ ] При неверном токене (401) сервис логирует ошибку и уведомляет пользователя
- [ ] Плагин совместим с `plugin_api = 4` (Noctalia v5.0.0-beta.4+)

---

## 7. Референсы

- **Noctalia Plugin Development**: `https://docs.noctalia.dev/noctalia/plugins/development/`
- **Runtime API (httpStream, state)**: `https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/`
- **Plugin API Versions**: `https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/`
- **lazyagent HTTP API**: `https://lazyagent.dev/docs/interfaces/http-api/`
- **Пример плагина (ticker service + widget)**: официальный репозиторий `noctalia-dev/official-plugins`, директория `example/`
