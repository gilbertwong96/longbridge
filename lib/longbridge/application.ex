defmodule Longbridge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Longbridge.Finch, pools: finch_pools()},
      Longbridge.Symbol.Store
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Longbridge.Supervisor)
  end

  defp finch_pools do
    %{
      default: [
        # `:httpc` default; Finch tunes its own pool.
        size: 10,
        count: 5
      ]
    }
  end
end
