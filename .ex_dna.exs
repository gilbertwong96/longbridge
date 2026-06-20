%{
  min_mass: 40,
  min_occurrences: 2,
  ignore: ["deps/**", "_build/**", "node_modules/**"],
  excluded_macros: [:schema, :pipe_through, :plug],
  normalize_pipes: true
}
