def median:
  sort |
  if length == 0 then null
  elif (length % 2) == 1 then .[(length / 2 | floor)]
  else ((.[(length / 2) - 1] + .[length / 2]) / 2)
  end;

def only_arm($name):
  map(select(.arm == $name)) |
  if length != 1 then error("each task/repetition must contain exactly one " + $name + " arm")
  else .[0]
  end;

. as $runs |
[
  $runs | group_by(.task)[] |
  . as $task_runs |
  [
    $task_runs | group_by(.repetition)[] |
    . as $pair |
    ($pair | only_arm("vanilla")) as $vanilla |
    ($pair | only_arm("baseline")) as $baseline |
    {
      repetition: $vanilla.repetition,
      vanilla_pass: $vanilla.pass,
      baseline_pass: $baseline.pass,
      pass_delta: ((if $baseline.pass then 1 else 0 end) - (if $vanilla.pass then 1 else 0 end)),
      elapsed_ms_delta: ($baseline.elapsed_ms - $vanilla.elapsed_ms),
      input_tokens_delta: ($baseline.input_tokens - $vanilla.input_tokens),
      output_tokens_delta: ($baseline.output_tokens - $vanilla.output_tokens),
      commands_delta: ($baseline.commands - $vanilla.commands),
      changed_files_delta: ($baseline.changed_files - $vanilla.changed_files),
      unnecessary_files_delta: ($baseline.unnecessary_files - $vanilla.unnecessary_files),
      failed_command_events_delta: ($baseline.failed_command_events - $vanilla.failed_command_events),
      subagent_events_delta: ($baseline.subagent_events - $vanilla.subagent_events)
    }
  ] as $pairs |
  {
    task: $task_runs[0].task,
    class: $task_runs[0].class,
    repetitions: ($pairs | length),
    vanilla_pass_rate: (($task_runs | map(select(.arm == "vanilla" and .pass)) | length) / ($pairs | length)),
    baseline_pass_rate: (($task_runs | map(select(.arm == "baseline" and .pass)) | length) / ($pairs | length)),
    pass_rate_delta: (
      (($task_runs | map(select(.arm == "baseline" and .pass)) | length) -
       ($task_runs | map(select(.arm == "vanilla" and .pass)) | length)) /
      ($pairs | length)
    ),
    paired: $pairs
  }
] as $tasks |
[$tasks[].paired[]] as $pairs |
{
  schema: 1,
  contract: "codex-baseline-benchmark-summary/v1",
  comparison: "paired-vanilla-vs-baseline",
  runs: ($runs | length),
  pairs: ($pairs | length),
  by_arm: [
    $runs | group_by(.arm)[] |
    {
      arm: .[0].arm,
      runs: length,
      passes: (map(select(.pass)) | length),
      pass_rate: ((map(select(.pass)) | length) / length),
      median_elapsed_ms: (map(.elapsed_ms) | median),
      input_tokens: (map(.input_tokens) | add),
      output_tokens: (map(.output_tokens) | add),
      commands: (map(.commands) | add),
      changed_files: (map(.changed_files) | add),
      unnecessary_files: (map(.unnecessary_files) | add),
      failed_command_events: (map(.failed_command_events) | add),
      subagent_events: (map(.subagent_events) | add)
    }
  ],
  paired_outcomes: {
    both_pass: ($pairs | map(select(.vanilla_pass and .baseline_pass)) | length),
    baseline_only_pass: ($pairs | map(select((.vanilla_pass | not) and .baseline_pass)) | length),
    vanilla_only_pass: ($pairs | map(select(.vanilla_pass and (.baseline_pass | not))) | length),
    neither_pass: ($pairs | map(select((.vanilla_pass | not) and (.baseline_pass | not))) | length)
  },
  by_task: $tasks,
  inference: {
    confidence_interval: null,
    reason: "The default three paired repetitions per task are too few for a defensible confidence interval. Report raw pairs and variance; do not claim superiority from this suite alone."
  },
  limitations: [
    "Public development fixtures can be learned or overfit.",
    "Retry count and independent review findings are not observable in stable JSONL and remain null in raw results.",
    "Token and tool-event metrics depend on the installed Codex JSONL schema."
  ]
}
