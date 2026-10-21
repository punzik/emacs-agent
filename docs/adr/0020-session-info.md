# ADR-0020: Информация о сессии для пользователя и кода

Статус: согласовано пользователем, реализовано; verification ниже.

## Причина и граница

Пользователю и Elisp-коду (включая модель через `eval_elisp`) нужен обзор
состояния одной conversation: идентичность, scope, активность, объём истории,
compaction, usage и сохранённость. Согласовано: две функции, тонкая презентация,
честные токены из уже существующего учёта. Нет новых tools, реестров, таймеров,
автообновлений или отдельного UI-фреймворка.

## Решение

`emacs-agent-session-info (&optional SESSION)` — неинтерактивная, возвращает
plist. SESSION — объект или ID string; nil разрешается как владелец текущего
журнала или выбранная conversation scope (`emacs-agent--current-session`).
Читается только живое состояние: без model request, загрузки архивов, запуска
run, сохранения и создания журнала.

Ключи: :name (collision-resistant имя), :id, :id-short (префикс 64-hex
части собственного ID: canonical IDs имеют форму `session-<64hex>`, их
handle — сам этот hex, поэтому short визуально совпадает с началом ID;
неканонические ID используют sha256-fallback через
`emacs-agent-session-id-handle`; handle — только отображение, identity
остаётся полным ID),
:scope (key, с fallback на project-root, иначе `global`), :created-at,
:updated-at, :run-status (`idle` без активного run), :pending-runs,
:pending-inputs (недоставленные steering inputs), :source-buffer и
:source-buffer-alive (последний живой рабочий буфер), :messages/:events
(длины canonical history и журнала), :compaction (:cut :summary-length
:tokens-before :model :backend :time) или nil, :compaction-job-state пока
существует runtime job, :provenance и :usage-anchor без изменений, :usage,
:saved-file, :saved (file-exists-p), :log-buffer-alive.

`emacs-agent-session-info-show` — интерактивная: форматирует plist первой
функции в read-only special-mode буфер `*emacs-agent-info: NAME*`, привязывает
владельца и project-root default-directory — тот же паттерн, что
`emacs-agent-show-instructions`. Не меняет selection и не запускает run.

Форматирование — внутренний слой (`emacs-agent-session-info--format/--time`);
значения `unknown` отображаются явно, не как нули.

## Usage

`emacs-agent-usage-session-summary (SESSION)` в `emacs-agent-usage.el` —
сессионные строгие суммы по durable `usage` событиям журнала (одному на каждый
завершённый HTTP request любого run; текущий in-flight request отсутствует до
своего завершения). Семантика разделяет `emacs-agent-usage-summary`: gptel-
normalized, input excludes cache, суммы — расход по запросам, не размер
контекста; unknown распространяется, не притворяясь нулём; input-total
складывает input+cache, total добавляет output. Compaction не «приводит» суммы
истории — факт компакции виден соседним полем. Это описательные метаданные,
не billing и не сертификация edit/save/check; cache-поведение провайдера не
интерпретируется.

## Проверка

386 ERT (7 новых), warnings-as-errors compilation, diff-check. Новые регрессии:
строгие поля и суммы с известными числами; unknown-пропагация и пустые суммы;
compaction-проекция и формат; разрешение объектом/ID/владельцем журнала и
ошибки (незарегистрированный ID, неверный тип, отсутствие сессии); read-only
буфер с владельцем/default-directory/содержимым без запуска run; global
selection со статусом pending, saved-файлом и fallback scope; short-ID
совпадает с префиксом canonical ID hex, journal/session-name и picker
используют тот же handle, sha256-fallback для legacy-формы ID. Без gptel в
изолированном прогоне нового файла; без provider calls, live user-Emacs или
изменения persistence.