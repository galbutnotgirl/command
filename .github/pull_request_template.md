## Summary

- 

## User Impact

- [ ] App behavior changed
- [ ] User-facing docs changed
- [ ] Release/update behavior changed
- [ ] Support/security routing changed
- [ ] Internal-only change

## Fit And Finish Checks

- [ ] User-facing labels match docs.
- [ ] Paired Markdown/HTML docs are updated when needed.
- [ ] Support, Privacy, and Security guidance still route sensitive diagnostics away from public issues.
- [ ] Issue templates, issue chooser, and repo trust files are updated when support/reporting routes change.
- [ ] Release checklist or changelog updated when behavior/defaults changed.
- [ ] Bundled docs/release asset smoke passes when docs or release packaging changed.

## Validation

Paste relevant results:

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
cd ../.. && ./test/test-shell.sh
./test/test-install-state.sh
./test/test-updater-swap.sh
./test/test-release-policy.sh
python3 ./test/test-docs.py
python3 ./test/test-pages.py
python3 ./test/test_string_review.py
./release.sh --skip-checks
./test/test-release-asset.sh
```

## Notes

- 
