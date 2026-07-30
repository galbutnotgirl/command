# Command Repository Rules

## Installed Runtime Qualification

For app-runtime changes that will be installed locally, commit changes first, then run:

```bash
time ./qualify-installed-build.sh
```

Do not report installed build as validated unless command passes and
`dist/installed-qualification.json` names current commit. Qualification must use
incremental install. Never set `COMMAND_CLEAN_INSTALL` or change signing identity
unless user explicitly requests clean-install testing.

Command runs full release gates, signed build, incremental install, installed
identity check, microphone capture before and after restart, runtime soak, and
final-word model fixtures. Microphone checks inject one failure after live
buffers, prove full capture-resource cleanup, and require immediate production
retry across repeated cycles. Tagged Fn down/up also travels through installed
event-tap voice dispatch before recording. It does not publish GitHub release.
