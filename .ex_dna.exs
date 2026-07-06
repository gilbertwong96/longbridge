%{
  min_mass: 55,
  min_occurrences: 2,
  ignore: ["deps/**", "_build/**", "node_modules/**", "lib/longbridge/_protos.ex"],
  excluded_macros: [:schema, :pipe_through, :plug],
  normalize_pipes: true
}
