# План реализации: плагин Noctalia `lazyagent-monitor`

> **Статус (15.10, ~17:00): Фазы 1–4 выполнены.** Плагин установлен в
> Noctalia v5.2.1 по path-source `inner`, включён, виджет в баре.
> Реальные расхождения, выявленные при интеграции:
> 1. Path source ожидает подпапку с плагином — файлы перенесены в
>    `lazyagent-monitor/` внутри репозитория.
> 2. PATH процесса Noctalia не содержит `~/go/bin` → добавлена настройка
>    `lazyagent_bin` (заполнена в `settings.toml`).
> 3. Токен пользователь ввёл через GUI (заполнен в `settings.toml`),
>    авто-разрешение через `lazyagent passphrase --show` остаётся fallback.
> 4. Живой конфиг Noctalia — `~/.local/state/noctalia/settings.toml`
>    (GUI periodically rewrite'ит его; `~/.config/noctalia/config.toml` —
>    пустой, дублировать таблицы в нём нельзя).
> 5. Тест 401 пройден штатно (пользователь сам прописал токен); тест
>    «сервер остановлен» не выполнялся (lazyagent без systemd — risky),
>    кодовая ветка общая с 401-переподключением.
> 6. Метрики дедупа в логах: ~500 heartbeat'ов отфильтровано при ~10
>    публикациях.


Плагин для Noctalia Shell v5+ (установлена v5.2.1), отображающий в баре активность
LLM-агентов через SSE API локального сервиса `lazyagent` (`http://127.0.0.1:7421`,
сейчас запущен, pid 846374).

Архитектура: `[[service]]` (bridge, SSE-клиент) + `[[widget]]` (бар-виджет),
обмен только через `noctalia.state` (изоляция VM).

---

## 1. Факты, проверенные в окружении (15.10)

| Факт | Значение |
|------|----------|
| Noctalia | v5.2.1, `/usr/local/bin/noctalia`, `~/.config/noctalia` пока **нет** |
| lazyagent | запущен на `127.0.0.1:7421`, исходники в `/home/inner/dev/lazyagent` |
| `~/.config/lazyagent/config.json` | есть `api_passphrase`, `api_salt`; **нет** `bearer_token` |
| Токен | выводится PBKDF2-SHA256(passphrase, salt, 600 000 итераций, 32 байта) → base64url без padding (см. `internal/apiauth/derive.go`) |
| Токен для SSE | только через `?token=<token>` query-параметр (заголовки не поддерживаются) |
| 401 | `onClose` получает `{ ok = true, status = 401 }` — статус приходит в onClose, тело ошибки идёт в onLine |

## 2. Отклонения от `application_task.md` (исправления по актуальной документации)

1. **`noctalia.setTimeout()` не существует.** Планирование на таймере — через
   `noctalia.setUpdateInterval(1000)` + флаг `nextReconnectMs` и
   `noctalia.nowMs()` (нужен `plugin_api ≥ 12`).
2. **Чтение токена из `bearer_token` не работает** — такого поля нет.
   Порядок разрешения токена (см. §4.2):
   1. плагин-настройка `token` (пользователь вставил вручную);
   2. `noctalia.runAsync({ "lazyagent", "passphrase", "--show" }, cb)` —
      подкоманда независима от сервера, печатает текущий токен в stdout;
   3. поле `bearer_token` из `config.json` (на будущее, если lazyagent его добавит).
   PBKDF2 в Luau не реализуем (600k итераций — недопустимо дорого для VM плагина).
3. **Дедупликация по «отпечатку»** из задачи оставляем, но добавляем
   `last_activity` в отпечаток — иначе виджет «застрянет» на старом состоянии,
   пока активность не поменяет `activity`/`is_active`.

## 3. Структура плагина

```
lazyagent-monitor/                  # == корень этого репозитория (имя = id после "/")
  plugin.toml
  service.luau                      # [[service]] id="bridge"
  widget.luau                       # [[widget]] id="monitor"
  README.md
  translations/en.json              # подписи настроек (обязательно, т.к. есть settings)
  thumbnail.webp                    # 960×540, только для community — фаза 6
```

`plugin.toml` (минимум):

```toml
id         = "inner/lazyagent-monitor"
name       = "Lazyagent Monitor"
version    = "1.0.0"
plugin_api = 12                      # nowMs(); httpStream требует 4
license    = "MIT"
description= "Displays LLM agent activity from the lazyagent API in the bar"
tags       = ["llm", "agents", "monitor"]
dependencies = ["lazyagent"]

[[setting]]                          # plugin-level: общий для service
key         = "token"
type        = "string"
label_key   = "settings.token.label"
description_key = "settings.token.description"
default     = ""

[[widget]]
id    = "monitor"
entry = "widget.luau"

[[service]]
id    = "bridge"
entry = "service.luau"
```

## 4. Фаза 1 — сервис (`service.luau`)

Топ-левый уровень (инициализация) + `update()` (интервал 1000 мс):

1. **Разрешение токена** (см. §2.2). Кэшировать в `noctalia.state` под ключом
   `"token"` вместе с источником; при 401 — сбросить кэш и вычесть заново.
2. **SSE-подключение**:
   ```lua
   stream = noctalia.httpStream({
     url = "http://127.0.0.1:7421/api/events?token=" .. token,
   }, onLine, onClose)
   ```
3. **Парсинг в `onLine(line)`**:
   - строки, начинающиеся `data:` — срезать префикс, `noctalia.json.decode`;
   - `event:` и пустые строки игнорировать;
   - JSON-ошибку — `noctalia.log`, пропустить строку (не ронять VM).
4. **Дедупликация (отпечаток)**:
   ```
   fp = string.join(сортированные "session_id:activity:is_active:short_name")
      .. "|stats:" .. total .. ":" .. active
   ```
   fp совпадает с предыдущим → не публиковать.
5. **Публикация** `noctalia.state.set("snapshot", {...})`:
   ```lua
   {
     sessions = { { agent, activity, is_active, short_name, model, cost_usd } ... },
     stats    = { total = n, active = m, window_minutes = w },
     agents   = { ["pi"] = { total = n, active = m }, ... },  -- агрегат по агентам
     receivedAtMs = noctalia.nowMs(),
   }
   ```
   Значения state — plain data (копируются между VM).
6. **Переподключение в `onClose(result)`**:
   - `result.status == 401` → сбросить кэш токена, `noctalia.notifyError`
     «проверьте токен lazyagent», таймаут повторного подключения 30 с
     (не спамить) + повторное разрешение токена через `passphrase --show`;
   - иначе → `nextReconnectMs = nowMs() + 5000`.
   - В `update()`: если `stream == nil and nowMs() >= nextReconnectMs` —
     попробовать переподключиться (перепроверив токен при 401-истории).
   - Перед стартом/переподключением вызывать `stream:stop()` idempotent-но
     (stop подавляет onClose — защита от дублей).
7. **Логирование**: `noctalia.log` — подключение, количество опубликованных
   и пропущенных (dedup) событий, ошибки. Это даст доказательство дедупа
   при приёмке.

## 5. Фаза 2 — виджет (`widget.luau`)

1. Стартовое состояние: `barWidget.setGlyph("robot")` (или "terminal"),
   `setText("—")`, tooltip «noctalia/lazyagent-monitor: connecting…»
2. `noctalia.state.watch("snapshot", fn)`:
   - `setText("%d/%d")` — `active/total`;
   - цвет: `setColor("ok"/"#22C55E")` если active > 0, `setColor("disabled"/серый)`
     если 0 (роли палитры — проверить в `~/.config/noctalia` при интеграции,
     fallback на hex);
   - tooltip: массив строк «pi: 1 active», «opencode: 0 active» + строка
     `total/active` и окно (`window_minutes`).
3. Защита от «застывшего» состояния: если `receivedAtMs` старше ~90 с —
   показать `?` / серый цвет (сервис потерял поток).

## 6. Фаза 3 — локальная интеграция и тесты

1. Настроить Noctalia (конфига ещё нет, создаётся при первом запуске):
   - запустить `noctalia` из терминала (логи в консоль);
   - в `~/.config/noctalia/config.toml`:
     ```toml
     [plugins]
     enabled = ["inner/lazyagent-monitor"]

       [[plugins.source]]
     enabled = true
     kind = "path"
     name = "inner"
     location = "/home/inner/dev/lazyagent-monitor"
     ```
2. В бар добавить виджет `type = "inner/lazyagent-monitor:monitor"`
   (Settings → Bar / plugin settings).
3. **Матрица тестов** (критерии приёмки):
   - [ ] плагин виден в Settings → Plugins и включается;
   - [ ] сервис получает события: в логах `event: update` приходят,
     виджет показывает `active/total` (проверить curl'ом:
     `curl -s "http://127.0.0.1:7421/api/sessions"` с токеном из
     `lazyagent passphrase --show`);
   - [ ] дедуп: при heartbeat'ах счётчик «published» в логах не растёт;
   - [ ] tooltip с разбивкой по агентам;
   - [ ] `kill lazyagent` → через ~5 с сервис переподключается;
   - [ ] неверный токен (вставить мусор в setting) → 401 → notifyError,
     нет infinite loop;
   - [ ] hot reload: правка `.luau` применяется без перезапуска Noctalia.
4. Проверить в реальном сценарии: запустить pi/opencode-агента, увидеть
   смену `0/0 → 1/1` и активное состояние.

## 7. Фаза 4 — полировка и docs

- `translations/en.json`: `settings.token.label` = "lazyagent Bearer token",
  `settings.token.description` = "Leave empty to derive automatically via
  `lazyagent passphrase --show`.";
- `README.md` (корневой): установка, path source, настройка токена,
  troubleshooting (401, окно 30 мин, hot reload);
- опционально `icon` в манифесте.

## 8. Фаза 5 — (опционально, отдельно) публикация в community

Только по запросу: `thumbnail.webp` 960×540, полный `translations`,
бамп version, PR в `noctalia-dev/community-plugins` (1 PR = 1 плагин).

## 9. Риски

| Риск | Митигация |
|------|-----------|
| Роли палитры для `setColor` неизвестны заранее | fallback на hex; проверить в палитре темы при интеграции |
| `lazyagent passphrase --show` может печатать и предупреждения в stdout | парсить строку, похожую на 43-символьный base64url-токен |
| SSE-строки могут приходить не по одной строке (chunking) — httpStream даёт onLine на каждую полученную строку, CR срезает рантайм | доверять onLine; не парсить «по буферу» |
| Токен в URL-строке попадает в логи Noctalia | токен не логируем; в README предупреждение (в lazyagent доках тоже так) |
| `offline_mode` Noctalia блокирует httpStream | проверить при интеграции, при необходимости — в README |

## 10. Порядок работы

1. Фаза 1: `plugin.toml` + `service.luau` (ядро).
2. Фаза 2: `widget.luau`.
3. Фаза 3: интеграция в Noctalia + прогон матрицы тестов.
4. Фаза 4: README + переводы + фиксы по результатам тестов.
5. Фаза 5 — по решению пользователя.
