defmodule Longbridge.DCAContext do
  @moduledoc """
  Dollar-cost averaging (DCA) plan context.

  Manages recurring buy plans: create, list, update, pause, resume,
  and stop.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, plan} = Longbridge.DCAContext.create_plan(config,
        symbol: "AAPL.US",
        amount: "100.00",
        frequency: :weekly
      )
  """

  alias Longbridge.{Config, HTTPClient}

  @type frequency :: :daily | :weekly | :biweekly | :monthly

  # The upstream DCA API lives under `/v1/dailycoins/*`. Plan state changes
  # (pause / resume / stop) all share a single `/v1/dailycoins/toggle`
  # endpoint that takes a `status` field.
  @list_path "/v1/dailycoins/query"
  @create_path "/v1/dailycoins/create"
  @update_path "/v1/dailycoins/update"
  @toggle_path "/v1/dailycoins/toggle"

  @status_active "Active"
  @status_suspended "Suspended"
  @status_finished "Finished"

  @doc """
  Creates a new DCA plan.

  ## Options

  - `:symbol` — target symbol (required)
  - `:amount` — amount per period (required)
  - `:frequency` — `:daily`, `:weekly`, `:biweekly`, `:monthly` (required)
  - `:day_of_week` — for weekly frequency, e.g. `"Monday"`
  - `:day_of_month` — for monthly frequency, `"1"` through `"31"`
  - `:allow_margin` — boolean, defaults to `false`
  """
  @spec create_plan(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_plan(%Config{} = config, opts) do
    body =
      opts
      |> Map.new()
      |> Map.put_new(:allow_margin, false)
      |> Jason.encode!()

    HTTPClient.request_json(:post, @create_path, body, config)
  end

  @doc """
  Lists all DCA plans. Supports pagination.

  ## Options

  - `:page` — 1-indexed page (default `1`)
  - `:limit` — page size (default `100`)
  - `:status` — `:active`, `:suspended`, or `:finished`
  - `:symbol` — filter by symbol
  """
  @spec list_plans(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_plans(%Config{} = config, opts \\ []) do
    params =
      [
        page: Keyword.get(opts, :page, 1),
        limit: Keyword.get(opts, :limit, 100),
        status: encode_status(Keyword.get(opts, :status)),
        counter_id: Keyword.get(opts, :symbol)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()

    HTTPClient.request_json(:get, @list_path, "", config, params: params)
  end

  @doc """
  Updates an existing plan. Same options as `create_plan/2` plus `:plan_id`.
  """
  @spec update_plan(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_plan(%Config{} = config, opts) do
    body = Jason.encode!(Map.new(opts))
    HTTPClient.request_json(:post, @update_path, body, config)
  end

  @doc "Pauses an active plan by `plan_id`."
  @spec pause_plan(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def pause_plan(%Config{} = config, plan_id) do
    toggle(config, plan_id, @status_suspended)
  end

  @doc "Resumes a paused plan by `plan_id`."
  @spec resume_plan(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume_plan(%Config{} = config, plan_id) do
    toggle(config, plan_id, @status_active)
  end

  @doc """
  Stops (permanently finishes) a plan by `plan_id`.

  The upstream API does not expose a true DELETE; finishing is the
  irreversible terminal state.
  """
  @spec delete_plan(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_plan(%Config{} = config, plan_id) do
    toggle(config, plan_id, @status_finished)
  end

  @doc """
  Fetches a single plan by `plan_id` from the list endpoint.

  The upstream API does not have a per-plan detail endpoint; this helper
  filters the list response so callers that only want one plan don't have
  to walk the pagination.
  """
  @spec plan_detail(Config.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def plan_detail(%Config{} = config, plan_id) do
    case list_plans(config, limit: 100) do
      {:ok, %{"plans" => plans}} when is_list(plans) ->
        {:ok, Enum.find(plans, &(&1["plan_id"] == plan_id))}

      {:ok, other} ->
        {:ok, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Helpers ──────────────────────────────────────────────

  defp toggle(config, plan_id, status) do
    body = Jason.encode!(%{plan_id: plan_id, status: status})
    HTTPClient.request_json(:post, @toggle_path, body, config)
  end

  defp encode_status(:active), do: @status_active
  defp encode_status(:suspended), do: @status_suspended
  defp encode_status(:finished), do: @status_finished
  defp encode_status(other) when is_binary(other), do: other
  defp encode_status(nil), do: nil
end
