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

Never install `Command.app` produced directly by `build-agent.sh`. Direct builds are
unqualified development artifacts. `install-agent.sh`, in-app updater, and detached
swapper must reject bundles without signed commit-bound regression attestation.
Do not set `COMMAND_ALLOW_UNQUALIFIED_INSTALL` outside isolated installer tests.
Do not launch direct build as daily app. `script/build_and_run.sh` requires explicit
`--allow-unqualified` and is limited to isolated UI development.

Command runs full release gates, signed build, incremental install, installed
identity check, microphone capture before and after restart, runtime soak, and
final-word model fixtures. Microphone checks inject one failure after live
buffers, prove full capture-resource cleanup, and require immediate production
retry across repeated cycles. Tagged Fn down/up also travels through installed
event-tap voice dispatch before recording. It does not publish GitHub release.
