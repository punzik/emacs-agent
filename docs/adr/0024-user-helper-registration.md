# ADR-0024: Структурированное описание пользовательских хелперов

Статус: согласовано пользователем, реализовано; verification ниже.

## API и формат

Глобальный runtime-реестр обычных Elisp-функций, не новые model tools:

```elisp
(emacs-agent-register-helper
 'my-diagnostics
 :description "Read current buffer diagnostics."
 :returns "List of (:line :column :severity :message)."
 :constraints "Requires an active checker; does not save or modify buffers."
 :example "(my-diagnostics \"main.ml\")")
(emacs-agent-unregister-helper 'my-diagnostics)
```

`:description` и `:returns` — обязательные непустые строки. Необязательные
`:constraints` и `:example`, если переданы, тоже непустые строки. Неизвестные
и повторные ключи отклоняются. Подробный help описывает назначение полей,
координаты, побочные эффекты, save и продолжение вывода; рекомендует короткие
описания без повторения общей инструкции или полного docstring.

Имя и сигнатура получаются из загруженной функции, без вызова функции или
загрузки autoload. Приоритет у declared usage в документации (`cl-defun`
иначе скрывает `&key` за `&rest`), затем `help-function-arglist`. Неизвестная
сигнатура — явная ошибка с рекомендацией Lisp wrapper. Макросы, special forms,
неопределённые функции и autoload (в том числе через alias) не регистрируются.
Проверяется resolved definition, а не symbol `function-documentation`
(свойство может содержать вычисляемое Lisp-выражение). Override этого свойства
игнорируется, в том числе для aliases и arglist fallback.
Заявленная Emacs usage не является независимой проверкой реализации.

Повторная регистрация атомарно заменяет запись после всех проверок.
Сигнатура фиксируется при регистрации; после переопределения функции нужно
зарегистрировать её снова. Регистрация возвращает символ функции;
unregister — t при удалении записи, nil при её отсутствии. Код загружается
пользователем отдельно; сохранённое описание не определяет функцию.

В system prompt один блок, отсортированный по имени функции:

```text
User helpers (via eval_elisp):
(my-diagnostics buffer)
  Read current buffer diagnostics.
  Returns: List of (:line :column :severity :message).
  Constraints: Requires an active checker; does not save or modify buffers.
  Example: (my-diagnostics "main.ml")
```

Сигнатура печатается в обычной форме вызова `(NAME ARGS...)`. Отсутствующие
необязательные поля не выводятся. Prose сводится к одной строке, text
properties удаляются; пример — буквальный текст, без чтения/eval или
исправления quoting. Полный docstring не включается.

## Frozen input и доставка

Необязательный `:helpers` (готовая строка блока) добавляется в instructions
snapshot при submission, независимо от project root и opt-out файлов.
Порядок: базовый prompt, общий AGENTS/CLAUDE, EMACSAGENT.md, user helpers.
Пустой реестр не меняет prompt. Встроенные инструкции не переписываются.

FIFO, tool continuation и explicit recovery сохраняют исходный текст;
изменения реестра влияют только на новые inputs. Текст включается в pending
byte quota и обычный request context budget. Snapshot сохраняется как данные,
но registry/функции не восстанавливаются из него. Instructions view показывает
frozen блок без обращения к текущему реестру. Подготовка steering фиксирует
тот же snapshot; текущий активный run не заменяет свой system prompt через
steering, как и для project instructions.

Регистрация — подсказка модели, не whitelist, sandbox или выдача полномочий.
Unregister не отзывает уже отправленное описание и не делает функцию
недоступной unrestricted eval. Лимиты output/read и побочные эффекты остаются
ответственностью самого хелпера. Ни регистрации code/примеров из файлов,
ни автоматического выполнения примеров, ни нового framework расширений нет.

## Проверка

421 ERT (15 новых: 11 API/renderer и 4 lifecycle/budget) проходят на исходниках
и после компиляции; strict
warnings-as-errors compile и diff-check проходят. Unit tests проверяют
atomic metadata validation, no autoload/eval, aliases/CL/compiled signatures,
детерминированный компактный формат, optional fields и independent strings.
Regression для dynamic symbol documentation охватывает target/alias chain,
arglist fallback и невалидный metadata update: Lisp не вычисляется.
Интеграционные проверки: frozen FIFO и actual gptel wire, tool continuation
(HTTP подменён), inert pending restore/view без текущего registry, durable
validation, pending byte quota и context budget фактического запроса.

Manual compaction historical tokens-before preview остаётся прежней
history-only оценкой; реализация не меняет её и не переносит helper block
в tool-free summary prompt. Builtin system prompt не изменён.
Независимое review обнаружило implicit eval в symbol documentation; после
перехода на resolved definition исходный reproducer и alias/compiled probes
больше не выполняют Lisp. Повторная проверка fix подтверждена.
Provider calls и live user-Emacs smoke не выполнялись.
