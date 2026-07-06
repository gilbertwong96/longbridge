defmodule Longbridge.TradePushTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, TradeContext}

  @moduletag :trade_push

  defp encode_notification(notification) do
    {:ok, iodata, _size} = Protox.encode(notification)
    IO.iodata_to_binary(iodata)
  end

  describe "TradeContext push event handling" do
    test "end-to-end: callback receives the decoded event" do
      event_json =
        JSON.encode!(%{
          "order_id" => "99999",
          "symbol" => "AAPL.US",
          "status" => "PartiallyFilled",
          "filled_qty" => "50"
        })

      notification = %Longbridge.Trade.V1.Notification{
        topic: "/v1/trade/order_changed",
        content_type: :CONTENT_JSON,
        dispatch_type: :DISPATCH_DIRECT,
        data: event_json
      }

      config =
        Config.new(
          token: "test-token",
          http_url: "http://127.0.0.1:1"
        )

      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      Process.sleep(50)

      parent = self()

      TradeContext.set_on_order_changed(
        ctx,
        fn event -> send(parent, {:trade_event, event}) end
      )

      # Simulate a push from the connection
      push_msg = {:push, 18, encode_notification(notification)}
      send(ctx, {:longbridge, ctx, push_msg})

      assert_receive {:trade_event, event}, 2_000
      assert event["order_id"] == "99999"
      assert event["symbol"] == "AAPL.US"
      assert event["status"] == "PartiallyFilled"
      assert event["filled_qty"] == "50"

      Process.exit(ctx, :kill)
    end

    test "ignores pushes with empty topic" do
      notification = %Longbridge.Trade.V1.Notification{
        topic: "",
        content_type: :CONTENT_JSON,
        dispatch_type: :DISPATCH_DIRECT,
        data: ~s({"should":"be ignored"})
      }

      config =
        Config.new(
          token: "test-token",
          http_url: "http://127.0.0.1:1"
        )

      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      Process.sleep(50)

      parent = self()

      TradeContext.set_on_order_changed(
        ctx,
        fn event -> send(parent, {:event, event}) end
      )

      push_msg = {:push, 18, encode_notification(notification)}
      send(ctx, {:longbridge, ctx, push_msg})

      # Should NOT receive any event (empty topic)
      refute_receive {:event, _}, 500

      Process.exit(ctx, :kill)
    end

    test "ignores non-JSON content type" do
      notification = %Longbridge.Trade.V1.Notification{
        topic: "/v1/trade/order_changed",
        content_type: :CONTENT_PROTO,
        dispatch_type: :DISPATCH_DIRECT,
        data: ""
      }

      config =
        Config.new(
          token: "test-token",
          http_url: "http://127.0.0.1:1"
        )

      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      Process.sleep(50)

      parent = self()

      TradeContext.set_on_order_changed(
        ctx,
        fn event -> send(parent, {:event, event}) end
      )

      push_msg = {:push, 18, encode_notification(notification)}
      send(ctx, {:longbridge, ctx, push_msg})

      refute_receive {:event, _}, 500

      Process.exit(ctx, :kill)
    end
  end
end
