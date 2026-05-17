# akariyu.dev

> Your dev server, in your pocket.

A premium mobile app that turns your Linux server into a remote development
environment. Manage Claude Code sessions, edit files, monitor server health,
and run terminals — all from your phone with a minimalist, premium UI.

See [`akariyu-spec.md`](./akariyu-spec.md) for the full design and architecture.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Foundation — design system, SSH connect, secure storage, biometric lock | **In progress** |
| 1 | File explorer + terminal | — |
| 2 | Claude sessions | — |
| 3 | Git + server dashboard | — |
| 4 | Polish + notifications | — |

## Develop

```sh
cd akariyu
flutter pub get
flutter run            # against a connected device
flutter test           # unit + widget tests
dart analyze           # static checks
```

The Flutter project lives in [`akariyu/`](./akariyu).
