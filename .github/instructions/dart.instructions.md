---
applyTo: "**/*.dart"
---

# Flutter/Dart Coding Rules

- **mounted check** after EVERY `await` in StatefulWidget: `if (!mounted) return;`
- **Dispose** all controllers: AnimationController, TextEditingController, ScrollController, StreamSubscription, Timer
- **Localization**: use `S.of(context).keyName` — never hardcode English or Spanish strings
- **Theme**: black `#000000` background, gold `#FFD700` accents, Poppins font
- **State management**: StatefulWidget with controllers only (no Riverpod/Bloc/Provider)
- **Debug logging**: `debugPrint('[ScreenName] message')` with screen prefix
- **Null safety**: sound null safety, no unnecessary `!` operators, no `dynamic`
- **GPS smoothing**: use `SmoothMotion` from `lib/utils/smooth_motion.dart` — never decay exponential
- **Part files**: many screens use `part`/`part of` pattern
