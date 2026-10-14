# Emacs Agent

An Emacs Lisp agent using gptel and one unrestricted `eval_elisp` tool in the
live editor. Project conversations will be separate, not sandboxed.

**Status: stage 0 prototype only, not the finished MVP.**

- Specification: [docs/EMACS_AGENT_SPEC.md](docs/EMACS_AGENT_SPEC.md)
- Tested gptel baseline, integration decisions, risks and manual smoke test:
  [docs/GPTEL_INTEGRATION.md](docs/GPTEL_INTEGRATION.md)
- Prototype: `examples/emacs-agent-spike.el`
- Reusable evaluator: `emacs-agent-eval.el`

The next stages implement project sessions/context, run scheduling, transcript
UI, context-history policies and persistence, in that order. No global
keybindings or user gptel configuration are changed.

## Test

Requires Emacs and the gptel revision documented above in an ELPA directory.
Tests use mocks and dry-run requests, not API keys.

```sh
nix-shell -p gnumake --run 'make clean test compile'
# Or with make already available:
make ELPA=/path/to/elpa test compile
```

## Security

Only connect to a trusted endpoint. `eval_elisp` can read secrets, execute shell
commands, modify editor configuration and delete files without confirmation.
Lisp executes synchronously and can block Emacs. Cancellation does not roll
back changes or guarantee termination of subprocesses.
