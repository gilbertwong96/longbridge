defmodule Longbridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :longbridge,
      version: "0.1.2",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      # excoveralls drives the coverage toolchain. Auto-generated protobuf
      # modules in lib/longbridge/_protos.ex are excluded via `skip_files`
      # in coveralls.json (excoveralls' documented file-exclusion mechanism)
      # — the `ignore_modules` key that used to live here was a no-op in
      # excoveralls 0.18 (the project config only reads `:tool`).
      #
      # The 80% coverage bar is enforced by codecov.yml's `status.project`
      # check on CI; it is NOT enforced locally — excoveralls' `coveralls.json`
      # task does not call `ensure_minimum_coverage/1` (only the local
      # `mix coveralls`, `coveralls.html`, and `coveralls.cobertura` tasks do).
      # Hand-written modules should each be near 100%; the 0.0% line for
      # lib/longbridge/oauth/token_storage.ex is a real gap to fill.
      test_coverage: [tool: ExCoveralls],
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
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      skip_undefined_reference_warnings_on: [
        "README.md",
        "CHANGELOG.md",
        "lib/longbridge/quote_context.ex",
        # References `Longbridge.OAuth.token_path/1` which is @doc false
        # (a back-compat shim kept for callers that imported it before
        # the public function was moved to FileTokenStorage).
        "lib/longbridge/oauth/file_token_storage.ex",
        # References `Longbridge.Connection.Session` defdelegates which
        # are @doc false (the Session module is internal-only; the
        # defdelegate is for clarity in the WSConnection code).
        "lib/longbridge/ws_connection.ex",
        # References `Longbridge.Application` which is @doc false
        # (Application modules are entrypoints, not part of the
        # public API).
        "lib/longbridge/symbol/store.ex"
      ]
    ]
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
        # Run coverage through excoveralls so `coveralls.json`'s `skip_files`
        # rule (excludes the auto-generated _protos.ex) is applied. `mix
        # test --cover` bypasses excoveralls entirely and would re-include
        # _protos.ex in the per-module HTML report.
        "coveralls.json"
      ],
      # Regenerate the pre-compiled protobuf modules in lib/longbridge/_protos.ex
      # from protos/*.proto. Requires `protoc` on $PATH (dev-only).
      gen_protos: [
        "protox.generate --output-path=lib/longbridge/_protos.ex --include-path=protos protos/control.proto protos/error.proto protos/api.proto protos/subscribe.proto"
      ]
    ]
  end

  defp deps do
    [
      {:protox, "~> 2.0"},
      {:openapi_protobuf_specs,
       github: "longbridge/openapi-protobufs",
       tag: "gen/go/v0.7.0",
       app: false,
       compile: false,
       only: [:dev, :test]},
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
      description: """
      Elixir SDK for the Longbridge OpenAPI trading platform — real-time
      market data, order submission, push subscriptions, and OAuth 2.0
      authentication for US, HK, SG, and CN markets.
      """,
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/gilbertwong96/longbridge",
        "Longbridge" => "https://open.longbridge.com"
      },
      files: ~w[lib protos .formatter.exs mix.exs README.md CHANGELOG.md LICENSE]
    ]
  end
end
