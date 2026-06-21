defmodule Longbridge.PortfolioContext do
  @moduledoc """
  Portfolio context.

  Provides exchange rates and portfolio P&L analysis.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, rates} = Longbridge.PortfolioContext.exchange_rates(config, "USD", ["HKD", "CNH"])
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Returns real-time exchange rates.

  `from_currency` is the base currency (e.g., `"USD"`).
  `to_currencies` is a list of target currencies (e.g., `["HKD", "CNH"]`).
  """
  @spec exchange_rates(Config.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def exchange_rates(%Config{} = config, from_currency, to_currencies) do
    currencies = Enum.join(to_currencies, ",")
    params = "from=#{from_currency}&to=#{currencies}"
    HTTPClient.request_json(:get, "/v1/portfolio/exchange_rates", "", config, params: params)
  end

  @doc """
  Returns portfolio profit & loss analysis.

  ## Options

  - `:currency` — filter by currency
  - `:type` — `:daily` or `:monthly`
  - `:start_date` — start of period (YYYY-MM-DD)
  - `:end_date` — end of period (YYYY-MM-DD)
  """
  @spec portfolio_pl(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def portfolio_pl(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/portfolio/pl", "", config,
      params: HTTPClient.build_query(opts)
    )
  end

  @doc "Returns portfolio position list with P&L breakdowns."
  @spec portfolio_positions(Config.t()) :: {:ok, map()} | {:error, term()}
  def portfolio_positions(%Config{} = config) do
    HTTPClient.request_json(:get, "/v1/portfolio/positions", "", config)
  end
end
