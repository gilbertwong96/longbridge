defmodule Longbridge.QuoteContext.RealtimeStoreTest do
  use ExUnit.Case, async: false

  alias Longbridge.Quote.V1, as: Q
  alias Longbridge.QuoteContext.RealtimeStore

  defp start_store do
    {:ok, store} = RealtimeStore.start_link(owner: self())
    store
  end

  describe "put_quote/2 + get_quote/2" do
    test "stores and returns the most recent PushQuote per symbol" do
      store = start_store()
      push = %Q.PushQuote{symbol: "AAPL.US", sequence: 1, last_done: "150.00"}
      RealtimeStore.put_quote(store, push)
      assert {:ok, [^push]} = RealtimeStore.get_quote(store, ["AAPL.US"])
    end

    test "returns nil for symbols not in the store" do
      store = start_store()
      assert {:ok, [nil, nil]} = RealtimeStore.get_quote(store, ["AAPL.US", "TSLA.US"])
    end

    test "overwrites earlier quotes for the same symbol" do
      store = start_store()
      first = %Q.PushQuote{symbol: "AAPL.US", sequence: 1, last_done: "150.00"}
      second = %Q.PushQuote{symbol: "AAPL.US", sequence: 2, last_done: "151.00"}
      RealtimeStore.put_quote(store, first)
      RealtimeStore.put_quote(store, second)
      assert {:ok, [^second]} = RealtimeStore.get_quote(store, ["AAPL.US"])
    end
  end

  describe "put_trades/2 + get_trades/3" do
    test "appends new trades and respects the 500-trade cap" do
      store = start_store()

      # Push 501 trades — only the last 500 should remain.
      trades =
        Enum.map(1..501, fn i ->
          %Q.Trade{price: to_string(i), volume: i, timestamp: i}
        end)

      push = %Q.PushTrade{symbol: "AAPL.US", sequence: 1, trade: trades}
      RealtimeStore.put_trades(store, push)

      assert {:ok, stored} = RealtimeStore.get_trades(store, "AAPL.US", 1000)
      assert length(stored) == 500
      assert hd(stored).price == "2"
      assert List.last(stored).price == "501"
    end

    test "returns trades capped to count" do
      store = start_store()

      push_trades = for i <- 1..10, do: %Q.Trade{price: to_string(i), volume: i}

      push = %Q.PushTrade{symbol: "AAPL.US", sequence: 1, trade: push_trades}
      RealtimeStore.put_trades(store, push)

      assert {:ok, last_three} = RealtimeStore.get_trades(store, "AAPL.US", 3)
      assert length(last_three) == 3
      assert List.last(last_three).price == "10"
    end

    test "returns [] when no trades have been pushed" do
      store = start_store()
      assert {:ok, []} = RealtimeStore.get_trades(store, "AAPL.US", 50)
    end
  end

  describe "reset/1" do
    test "clears all stored entries" do
      store = start_store()
      push = %Q.PushQuote{symbol: "AAPL.US", sequence: 1}
      RealtimeStore.put_quote(store, push)
      assert {:ok, [^push]} = RealtimeStore.get_quote(store, ["AAPL.US"])

      assert :ok = RealtimeStore.reset(store)
      assert {:ok, [nil]} = RealtimeStore.get_quote(store, ["AAPL.US"])
    end
  end
end
