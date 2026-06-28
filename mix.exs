defmodule Longbridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :longbridge,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 80],
        ignore_modules: ignore_modules()
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        flags: [:missing_return, :extra_return, :unmatched_returns]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :finch],
      mod: {Longbridge.Application, []}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/gilbertwong96/longbridge",
      homepage_url: "https://github.com/gilbertwong96/longbridge",
      extras: ["README.md"],
      skip_undefined_reference_warnings_on: [
        "README.md",
        "lib/longbridge/quote_context.ex"
      ]
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
  defp ignore_modules do
    # Auto-generated protobuf modules are exercised by encode/decode
    # round-trip tests in longbridge_test.exs, not by per-module coverage.
    ["_build/#{Mix.env()}/lib/longbridge/ebin/*.beam", "_build/dev/lib/longbridge/ebin/*.beam"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.map(fn path ->
      path |> Path.basename(".beam") |> String.to_atom()
    end)
    |> Enum.filter(fn mod ->
      mod_str = Atom.to_string(mod)
      String.contains?(mod_str, ".V1.") or mod == Longbridge.Protos
    end)
  end

  def cli do
    [preferred_envs: [ci: :test]]
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
        "reach.check --dead-code --smells",
        "test --cover"
      ]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:protox, "~> 2.0"},
      {:openapi_protobuf_specs,
       github: "longbridge/openapi-protobufs",
       tag: "gen/go/v0.7.0",
       app: false,
       compile: false,
       only: [:dev, :test]},
      {:pi_bridge, "~> 0.6", only: :dev},
      {:finch, "~> 0.18"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mint, "~> 1.9"},
      {:mint_web_socket, "~> 1.0"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.8", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      description:
        "Elixir SDK for the Longbridge OpenAPI trading platform — " <>
          "real-time market data, order submission, push subscriptions, " <>
          "and OAuth 2.0 authentication for US, HK, SG, and CN markets.",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/gilbertwong96/longbridge",
        "Upstream" => "https://github.com/longbridge/longbridge",
        "Longbridge" => "https://open.longbridge.com"
      },
      files: ~w[lib protos .formatter.exs mix.exs README.md]
    ]
  end
end
