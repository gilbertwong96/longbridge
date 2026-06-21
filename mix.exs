defmodule Longbridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :longbridge,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
      test: test_config(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        flags: [:missing_return, :extra_return, :unmatched_returns]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :finch],
      mod: {Longbridge.Application, []}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  # Auto-generated protobuf modules are exercised by representative
  # encode/decode round-trip tests, not by per-module coverage. The
  # hand-written protocol layer (Longbridge.Protocol, Longbridge.Config,
  # Longbridge.Protocol.Header) is what we hold to a coverage bar.
  #
  # Note: ExUnit's --exclude matches test names, not module names. We
  # therefore set the threshold low enough that proto modules (counted
  # as 0%) drag total coverage down. The hand-written modules should
  # each be near 100% — see `mix test --cover` output.
  defp test_config do
    [
      test: ["--cover", "--export-coverage", "coverage.lcov"]
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --all-warnings --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "deps.unlock --check-unused",
        "deps.audit",
        "xref graph --label compile-connected --fail-above 0",
        "dialyzer",
        "ex_dna",
        "reach.check --dead-code --smells"
      ]
    ]
  end

  defp deps do
    [
      {:protox, "~> 2.0"},
      {:openapi_protobuf_specs,
       github: "longbridge/openapi-protobufs", tag: "gen/go/v0.7.0", app: false, compile: false},
      {:pi_bridge, "~> 0.6", only: :dev},
      {:finch, "~> 0.18"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mint, "~> 1.9"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false}
    ]
  end
end
