defmodule Longbridge.DCAContext do
  @moduledoc """
  Dollar-cost averaging (DCA) plan context.

  Manages recurring buy plans: create, list, update, pause, resume,
  and delete.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, plan} = Longbridge.DCAContext.create_plan(config,
        symbol: "AAPL.US",
        amount: "100.00",
        currency: "USD",
        frequency: :weekly,
        start_date: "2024-01-15"
      )
  """

  alias Longbridge.{Config, HTTPClient}

  @type frequency :: :daily | :weekly | :biweekly | :monthly

  @doc """
  Creates a new DCA plan.

  ## Options

  - `:symbol` — target symbol (required)
  - `:amount` — amount per period (required)
  - `:currency` — settlement currency (required)
  - `:frequency` — `:daily`, `:weekly`, `:biweekly`, `:monthly` (required)
  - `:start_date` — first execution date, `"YYYY-MM-DD"` (required)
  - `:end_date` — optional end date
  - `:remark` — optional note
  """
  @spec create_plan(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_plan(%Config{} = config, opts) do
    body = Jason.encode!(Map.new(opts))
    HTTPClient.request_json(:post, "/v1/dca/plan/create", body, config)
  end

  @doc """
  Lists all DCA plans. Supports pagination.
  """
  @spec list_plans(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_plans(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/dca/plan/list", "", config,
      params: HTTPClient.build_query(opts)
    )
  end

  @doc "Gets details of a specific plan by `plan_id`."
  @spec plan_detail(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def plan_detail(%Config{} = config, plan_id) do
    HTTPClient.request_json(:get, "/v1/dca/plan/detail", "", config, params: "plan_id=#{plan_id}")
  end

  @doc """
  Updates an existing plan. Same options as `create_plan/2` plus `:plan_id`.
  """
  @spec update_plan(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_plan(%Config{} = config, opts) do
    body = Jason.encode!(Map.new(opts))
    HTTPClient.request_json(:post, "/v1/dca/plan/update", body, config)
  end

  @doc "Pauses an active plan by `plan_id`."
  @spec pause_plan(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def pause_plan(%Config{} = config, plan_id) do
    body = Jason.encode!(%{plan_id: plan_id})
    HTTPClient.request_json(:post, "/v1/dca/plan/pause", body, config)
  end

  @doc "Resumes a paused plan by `plan_id`."
  @spec resume_plan(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume_plan(%Config{} = config, plan_id) do
    body = Jason.encode!(%{plan_id: plan_id})
    HTTPClient.request_json(:post, "/v1/dca/plan/resume", body, config)
  end

  @doc "Deletes a plan by `plan_id`."
  @spec delete_plan(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_plan(%Config{} = config, plan_id) do
    body = Jason.encode!(%{plan_id: plan_id})
    HTTPClient.request_json(:post, "/v1/dca/plan/delete", body, config)
  end
end
