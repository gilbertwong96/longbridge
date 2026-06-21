defmodule Longbridge.AlertContext do
  @moduledoc """
  Price alert context.

  Manages price alerts: add, list, enable, disable, and delete.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, alert} = Longbridge.AlertContext.add_alert(config,
        symbol: "AAPL.US",
        price: "150.00",
        direction: :above
      )
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Creates a new price alert.

  ## Options

  - `:symbol` — stock symbol (required)
  - `:price` — trigger price (required)
  - `:direction` — `:above` or `:below` (required)
  - `:remark` — optional note
  """
  @spec add_alert(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_alert(%Config{} = config, opts) do
    body = Jason.encode!(Map.new(opts))
    HTTPClient.request_json(:post, "/v1/alert/add", body, config)
  end

  @doc "Lists all active price alerts."
  @spec list_alerts(Config.t()) :: {:ok, map()} | {:error, term()}
  def list_alerts(%Config{} = config) do
    HTTPClient.request_json(:get, "/v1/alert/list", "", config)
  end

  @doc "Enables a price alert by `alert_id`."
  @spec enable_alert(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def enable_alert(%Config{} = config, alert_id) do
    body = Jason.encode!(%{alert_id: alert_id})
    HTTPClient.request_json(:post, "/v1/alert/enable", body, config)
  end

  @doc "Disables a price alert by `alert_id`."
  @spec disable_alert(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def disable_alert(%Config{} = config, alert_id) do
    body = Jason.encode!(%{alert_id: alert_id})
    HTTPClient.request_json(:post, "/v1/alert/disable", body, config)
  end

  @doc "Deletes a price alert by `alert_id`."
  @spec delete_alert(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_alert(%Config{} = config, alert_id) do
    body = Jason.encode!(%{alert_id: alert_id})
    HTTPClient.request_json(:post, "/v1/alert/delete", body, config)
  end
end
