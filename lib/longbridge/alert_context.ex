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

  # Longbridge renamed the alerts API from `/v1/alert/*` to
  # `/v1/notify/reminders` (CRUD over the same resources). The wire shape
  # for the request bodies is preserved.
  @reminders_path "/v1/notify/reminders"

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
    HTTPClient.request_json(:post, @reminders_path, body, config)
  end

  @doc "Lists all active price alerts."
  @spec list_alerts(Config.t()) :: {:ok, map()} | {:error, term()}
  def list_alerts(%Config{} = config) do
    HTTPClient.request_json(:get, @reminders_path, "", config)
  end

  @doc """
  Updates a price alert — flips its `enabled` flag and re-sends all
  required fields (`indicator_id`, `frequency`, `scope`, `state`,
  `value_map`) so the server doesn't reject with
  `"invalid frequency"` / `"invalid indicator id"`.

  Pass the full alert item from `list_alerts/1`. The `enabled` key
  on `item` is the only field consulted as input — all other fields
  are forwarded verbatim to match upstream semantics.

  Endpoint: `POST /v1/notify/reminders`

  Added in `longbridge/openapi` 4.1.0 as a replacement for the old
  `enable`/`disable` methods.
  """
  @spec update(Config.t(), map(), boolean()) :: {:ok, map()} | {:error, term()}
  def update(%Config{} = config, item, enabled) when is_map(item) and is_boolean(enabled) do
    body =
      Jason.encode!(Map.merge(item, %{id: Map.get(item, "id"), enabled: enabled}))

    HTTPClient.request_json(:post, @reminders_path, body, config)
  end

  @doc """
  Enables a price alert by `alert_id`.

  Deprecated: use `update/3` instead. The old enable/disable methods
  send incomplete alert payloads, which the server now rejects with
  `"invalid frequency"` / `"invalid indicator id"` for alerts created
  through `add_alert/2`. `update/3` re-sends the full item to avoid
  the rejection.
  """
  @deprecated "Use update/3 with the alert item from list_alerts/1"
  @spec enable_alert(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def enable_alert(%Config{} = config, alert_id) do
    body = Jason.encode!(%{alert_id: alert_id, enable: true})
    HTTPClient.request_json(:post, @reminders_path, body, config)
  end

  @doc """
  Disables a price alert by `alert_id`.

  Deprecated: use `update/3` instead. See `enable_alert/2` for the
  upstream bug.
  """
  @deprecated "Use update/3 with the alert item from list_alerts/1"
  @spec disable_alert(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def disable_alert(%Config{} = config, alert_id) do
    body = Jason.encode!(%{alert_id: alert_id, enable: false})
    HTTPClient.request_json(:post, @reminders_path, body, config)
  end

  @doc """
  Deletes one or more price alerts by ID.

  Endpoint: `DELETE /v1/notify/reminders`

  Accepts a single `alert_id` string or a list of `alert_id` strings.
  Pass a list for batch delete (matches upstream 4.1.0+).
  """
  @spec delete_alert(Config.t(), String.t() | [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def delete_alert(%Config{} = config, alert_ids) when is_binary(alert_ids) do
    delete_alert(config, [alert_ids])
  end

  def delete_alert(%Config{} = config, alert_ids) when is_list(alert_ids) do
    body = Jason.encode!(%{ids: alert_ids})
    HTTPClient.request_json(:delete, @reminders_path, body, config)
  end
end
