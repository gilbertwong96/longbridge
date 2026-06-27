defmodule Longbridge.WSConnection.RateLimitTest do
  use ExUnit.Case, async: false

  alias Longbridge.WSConnection.RateLimit

  setup do
    RateLimit.init()
    RateLimit.reset()
    on_exit(fn -> RateLimit.reset() end)
    :ok
  end

  describe "init/0 + reset/0" do
    test "init creates a new ETS table" do
      try do
        :ets.delete(:longbridge_ws_rate_limit)
      rescue
        ArgumentError -> :ok
      end

      RateLimit.init()
      assert is_list(:ets.info(:longbridge_ws_rate_limit))
    end

    test "init is idempotent" do
      RateLimit.init()
      assert :ok = RateLimit.init()
    end

    test "reset clears all configured limits" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 5}
      ])

      assert RateLimit.wait_ms(11) == 0
      RateLimit.reset()
      assert RateLimit.wait_ms(11) == :infinity
    end
  end

  describe "set_limits/1" do
    test "applies server-supplied limits to the bucket" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 5}
      ])

      # Burst is 5, so the first 5 requests have wait_ms == 0.
      for _ <- 1..5 do
        assert RateLimit.wait_ms(11) == 0
      end

      # The 6th call needs to wait for a token to refill.
      assert RateLimit.wait_ms(11) > 0
    end

    test "overwrites previous limits" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 5}
      ])

      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 100, burst: 100}
      ])

      # New capacity is 100, so 100 requests should fit.
      for _ <- 1..100 do
        assert RateLimit.wait_ms(11) == 0
      end
    end

    test "handles the full command enum mapping" do
      RateLimit.set_limits([
        %{command: :QueryUserQuoteProfile, limit: 10, burst: 5},
        %{command: :QueryHistoryCandlestick, limit: 2, burst: 60},
        %{command: :QuerySecurityQuote, limit: 10, burst: 5}
      ])

      # Cmd codes per the proto: 4, 27, 11.
      assert RateLimit.wait_ms(4) == 0
      assert RateLimit.wait_ms(27) == 0
      assert RateLimit.wait_ms(11) == 0
    end

    test "maps every Longbridge.Quote.V1.Command atom to its cmd_code" do
      # Exhaustive table of all 24 known quote command atoms and their
      # wire-format cmd_code. Mirrors the `Command` enum in
      # openapi-protobufs/quote/api.proto. Each entry must produce a
      # configured bucket (wait_ms == 0) after a single set_limits
      # call, confirming the private cmd_to_code/1 clause works.
      mappings = [
        {4, :QueryUserQuoteProfile},
        {5, :Subscription},
        {6, :Subscribe},
        {7, :Unsubscribe},
        {8, :QueryMarketTradePeriod},
        {9, :QueryMarketTradeDay},
        {10, :QuerySecurityStaticInfo},
        {11, :QuerySecurityQuote},
        {12, :QueryOptionQuote},
        {13, :QueryWarrantQuote},
        {14, :QueryDepth},
        {15, :QueryBrokers},
        {16, :QueryParticipantBrokerIds},
        {17, :QueryTrade},
        {18, :QueryIntraday},
        {19, :QueryCandlestick},
        {20, :QueryOptionChainDate},
        {21, :QueryOptionChainDateStrikeInfo},
        {22, :QueryWarrantIssuerInfo},
        {23, :QueryWarrantFilterList},
        {24, :QueryCapitalFlowIntraday},
        {25, :QueryCapitalFlowDistribution},
        {26, :QuerySecurityCalcIndex},
        {27, :QueryHistoryCandlestick}
      ]

      for {cmd_code, command} <- mappings do
        RateLimit.set_limits([%{command: command, limit: 10, burst: 5}])
        # First request has a token; wait_ms must be 0.
        assert RateLimit.wait_ms(cmd_code) == 0,
               "expected wait_ms(#{cmd_code}) to be 0 for #{inspect(command)}"

        # Different cmd_code with no configured limit returns :infinity.
        assert RateLimit.wait_ms(cmd_code + 100) == :infinity
      end
    end

    test "passes through integer commands unchanged (cmd_to_code catch-all)" do
      # The catch-all `defp cmd_to_code(other) when is_integer(other)`
      # lets callers pass an already-integer cmd_code through set_limits
      # without going through the atom-to-integer mapping. Useful for
      # code that already has a numeric cmd_code.
      RateLimit.set_limits([%{command: 42, limit: 10, burst: 1}])
      assert RateLimit.wait_ms(42) == 0
    end
  end

  describe "wait_ms/1" do
    test "returns :infinity when no limit is configured for the cmd_code" do
      assert RateLimit.wait_ms(99) == :infinity
    end

    test "returns 0 while the bucket has tokens" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 5}
      ])

      assert RateLimit.wait_ms(11) == 0
    end

    test "returns a positive wait when the bucket is empty" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 1}
      ])

      # First call uses the only token.
      assert RateLimit.wait_ms(11) == 0
      # Second call must wait.
      assert RateLimit.wait_ms(11) > 0
    end

    test "the wait time is roughly 1 / refill_rate seconds" do
      # refill_rate=10 tokens/sec → empty bucket needs ~100ms to refill 1 token.
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 1}
      ])

      RateLimit.wait_ms(11)
      ms = RateLimit.wait_ms(11)

      # Allow generous tolerance: between 50ms and 200ms.
      assert ms >= 50, "wait_ms #{ms} below 50ms floor"
      assert ms <= 200, "wait_ms #{ms} above 200ms ceiling"
    end

    test "the bucket refills over time without explicit calls" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 10, burst: 1}
      ])

      RateLimit.wait_ms(11)
      Process.sleep(120)
      # After 120ms with rate=10/sec, the bucket has ~1.2 tokens.
      assert RateLimit.wait_ms(11) == 0
    end
  end
end
