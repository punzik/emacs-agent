# ADR-0008: Убрать pretty-print из синхронного autosave

Статус: реализовано по запросу пользователя об input lag; F2 UI временно отложен.

## Измерение

События streaming вызывают journal hooks и autosave синхронно в Emacs.
Полный снимок сохраняется на значимых событиях и частичных checkpoints.
На приватной копии реального журнала (~391 КБ, 96 canonical messages,
509 durable events), в offline Emacs с GC threshold как в рабочем Emacs:

| Участок | До | После |
| --- | ---: | ---: |
| Snapshot/validation/compaction, 10 повторов | ~5.5 мс | ~6.8 мс |
| Только recursive `pp`, 10 повторов | ~1050 мс | ~1031 мс (контроль) |
| Только `prin1`, 10 повторов | ~6.2 мс | ~6.6 мс (контроль) |
| Полный atomic save, 3 повтора | ~976 мс | ~14 мс |

Ни один из замеров не включал GC. Это локальный benchmark, не универсальная
гарантия latency. Приватные данные только читались как Lisp data; исходный
журнал и пользовательские исходники benchmark не изменял. Копии/метрики вне
репозитория, файлы 0600, каталог 0700.

Независимое исследование renderer без autosave показало примерно линейную
стоимость 6–55 мс суммарно на 1k–8k deltas; folded reasoning сохранял один
растущий overlay. Batch-attached windows не моделируют реальный redisplay,
поэтому интерактивные display-паузы этим не исключены. Также измерено
квадратичное накопление событий через nconc (8k deltas суммарно ~0.33 с), но
оно не объясняет секундный отдельный save; эти участки пока не меняем.

## Решение

Заменить `pp` в store-save небольшим линейным printer на основе `prin1`.
Top-level поля и отдельные messages/events/runs остаются на отдельных строках,
длинные строки по-прежнему escaped. Не строить рекурсивный pretty layout
внутри process callbacks. Человек при необходимости форматирует отдельную
приватную копию, не исполняя сохранённые формы.

Schema 2 и прочитанные Lisp values не меняются. Никакого перехода на append
journal/новую схему, worker/timer, отложенного terminal save или выключения
persistence. Частота checkpoints, немедленное сохранение значимых событий,
validation, compaction, temporary 0600 + atomic rename и обработка ошибок
сохраняются. Старые whitespace layouts читаются тем же reader.

## Проверка и границы

162 ERT и warnings-as-errors compilation прошли. Новая регрессия запрещает
вызов pp при save, проверяет точное равенство прочитанных данных snapshot,
Unicode/quotes/newlines/tabs/backslash/code-looking text, messages/events/runs
на отдельных строках и permissions. Существующие roundtrip/interrupted,
partial checkpoints, cycle/closure rejection и atomic-failure проверки проходят.
Приватный реальный sample также прочитан после нового printer: Lisp values
полностью equal исходным. В рабочем Emacs загружен свежий compiled store;
snapshot+print его in-memory сессии занял 16–18 мс в трёх пробах, без записи
на диск и без вызова модели. Это другой замер, не полный save benchmark выше.
Пользователь повторил живой тест и подтвердил: тормоза ввода исчезли.
Это подтверждение устранения наблюдавшейся проблемы, не универсальная
гарантия latency на любых размерах истории или произвольных eval/tools.
