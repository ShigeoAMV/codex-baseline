# Native PowerShell command-generation evaluation

This focused evaluation needs no API key. It deliberately remains separate from
the automated promotion suite because signed-in interactive Codex runs do not
provide the isolated, attested telemetry required for stable promotion.

Use the same existing signed-in Codex installation without copying or reading
authentication/session files. `vanilla` means the baseline global block is
absent; `baseline-solo` means it is installed with agents disabled. Confirm each
state with Doctor, alternate the arm order between repetitions, and start a new
task for every run.

For each `vanilla` and `baseline-solo` arm, and for each available PowerShell
5.1/7 engine:

1. Prepare a fresh workspace:
   `powershell -NoProfile -File run.ps1 -Mode Prepare -Workspace <absolute-path>`
2. Start a fresh signed-in Codex task in that workspace and provide `task.md`
   verbatim. Do not set an API key.
3. Record failed command and parser-error events. Do not coach or retry for the
   model.
4. Verify:
   `powershell -NoProfile -File run.ps1 -Mode Verify -Workspace <absolute-path>`
5. Repeat three times per arm and engine.

Report task pass rate, failed commands, and parser errors. Treat results only as
development evidence until the isolated live runner executes the same task
automatically.
