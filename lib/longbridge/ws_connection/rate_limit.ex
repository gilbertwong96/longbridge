defmodule Longbridge.WSConnection.RateLimit do
  @moduledoc false
  # Per-command-code leaky-bucket rate limiter for WS requests.
  #
  # Each command has a bucket with a `capacity` (max burst) and a
  # `refill_rate` (tokens added per second). On every request, the
  # bucket refills based on elapsed time, then attempts to take one
  # token. If the bucket has none, the caller sleeps for the time
  # it would take to refill enough tokens to send the request.
  #
  # This is a best-effort throttle, not a hard rate limiter — the
  # sleep is computed from the bucket state, so two concurrent calls
  # to the same connection can race the token decrement by a few
  # microseconds. The WS connection is single-threaded (it processes
  # one request at a time in `handle_call({:request, ...})`), so the
  # race is bounded.
  #
  # The limits are derived from `Longbridge.Quote.V1.UserQuoteProfileResponse.rate_limit`
  # and follow the upstream Rust SDK mapping:
  #
  #   Rust `RateLimit { interval, initial, max, refill }`
  #     = (1s,  burst,  burst,  limit)
  #
  # where `burst` is the bucket capacity and `limit` is tokens per second.
  #
  # The ETS value is a 4-tuple `{capacity, refill_rate, tokens, last_refill_at}`
  # so that `:ets.update_element/3` can do atomic per-field writes
  # without read-modify-write races on the GenServer.

  @ets :longbridge_ws_rate_limit

  @type cmd_code :: non_neg_integer()

  @doc """
  Initialize the per-command-code rate-limit table. Idempotent.
  """
  @spec init() :: :ok
  def init do
    _ =
      case :ets.info(@ets) do
        :undefined -> :ets.new(@ets, [:set, :named_table, :public, read_concurrency: true])
        _other -> :ok
      end

    :ok
  end

  @doc """
  Apply a list of `RateLimit` entries from the server, replacing
  any existing defaults. Each entry is
  `%Longbridge.Quote.V1.RateLimit{command, limit, burst}`.

  Unknown `command` values are skipped silently. The wire-format
  cmd_code mapping is hard-coded (the Quote Command enum).
  """
  @spec set_limits([map()]) :: :ok
  def set_limits(entries) do
    init()

    Enum.each(entries, fn %{command: cmd, limit: limit, burst: burst} ->
      case cmd_to_code(cmd) do
        code when is_integer(code) ->
          :ets.insert(
            @ets,
            {code, burst, limit, burst * 1.0, System.monotonic_time(:millisecond)}
          )

        _other ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Return the number of milliseconds the caller should sleep before
  sending a request with the given `cmd_code`. Returns `0` if the
  bucket has a token available. Returns `:infinity` if the command
  has no configured limit (no throttling).

  Updates the bucket atomically (refill + decrement). The decrement
  happens before the caller's sleep so a long wait doesn't let other
  callers race past an empty bucket.
  """
  @spec wait_ms(cmd_code()) :: non_neg_integer() | :infinity
  def wait_ms(cmd_code) when is_integer(cmd_code) do
    init()

    case :ets.lookup(@ets, cmd_code) do
      [] ->
        :infinity

      [{_, cap, rate, tok, time}] ->
        now = System.monotonic_time(:millisecond)
        {^cap, ^rate, tokens, now} = refill(cap, rate, tok, time, now)
        ms = compute_wait(cap, rate, tokens)

        # Atomically update tokens and last_refill_at. We may take a
        # token "early" (i.e. decrement before sleeping) so a subsequent
        # caller in the same GenServer turn doesn't see the same token
        # and also try to send.
        new_tokens = max(tokens - 1.0, 0.0)
        :ets.update_element(@ets, cmd_code, [{4, new_tokens}, {5, now}])

        ms
    end
  end

  @doc """
  Drop all configured limits. The next call to `wait_ms/1` will
  return `:infinity` for every cmd_code until `set_limits/1` is
  called again. Used by tests to start from a clean slate.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.info(@ets) do
      :undefined -> :ok
      _other -> :ets.delete_all_objects(@ets)
    end

    :ok
  end

  # Refill `tokens` based on the elapsed time since `last_refill_at`.
  # Caps the bucket at `capacity`. The monotonic clock is millisecond-
  # resolution, so refill rates below ~1 token/sec have coarse
  # granularity (acceptable for the documented rate limits).
  defp refill(cap, rate, tokens, last_refill_at, now) do
    elapsed_ms = max(now - last_refill_at, 0)
    new_tokens = elapsed_ms / 1000.0 * rate
    tokens = min(cap * 1.0, tokens + new_tokens)
    {cap, rate, tokens, now}
  end

  # Returns the milliseconds the caller must sleep before sending.
  # If a token is available, returns 0. Otherwise, returns
  # ceil((1 - tokens) / refill_rate * 1000).
  defp compute_wait(_cap, _rate, tokens) when tokens >= 1.0, do: 0

  defp compute_wait(_cap, rate, tokens) do
    deficit = 1.0 - tokens
    max(ceil(deficit / rate * 1000.0), 0)
  end

  # `rate_limit.command` is a `Longbridge.Quote.V1.Command` enum value
  # (atom). Map it to the wire-format cmd_code (non_neg_integer) the
  # WSConnection uses. Unknown values are passed through as-is so
  # callers can decide.
  defp cmd_to_code(:QueryUserQuoteProfile), do: 4
  defp cmd_to_code(:Subscription), do: 5
  defp cmd_to_code(:Subscribe), do: 6
  defp cmd_to_code(:Unsubscribe), do: 7
  defp cmd_to_code(:QueryMarketTradePeriod), do: 8
  defp cmd_to_code(:QueryMarketTradeDay), do: 9
  defp cmd_to_code(:QuerySecurityStaticInfo), do: 10
  defp cmd_to_code(:QuerySecurityQuote), do: 11
  defp cmd_to_code(:QueryOptionQuote), do: 12
  defp cmd_to_code(:QueryWarrantQuote), do: 13
  defp cmd_to_code(:QueryDepth), do: 14
  defp cmd_to_code(:QueryBrokers), do: 15
  defp cmd_to_code(:QueryParticipantBrokerIds), do: 16
  defp cmd_to_code(:QueryTrade), do: 17
  defp cmd_to_code(:QueryIntraday), do: 18
  defp cmd_to_code(:QueryCandlestick), do: 19
  defp cmd_to_code(:QueryOptionChainDate), do: 20
  defp cmd_to_code(:QueryOptionChainDateStrikeInfo), do: 21
  defp cmd_to_code(:QueryWarrantIssuerInfo), do: 22
  defp cmd_to_code(:QueryWarrantFilterList), do: 23
  defp cmd_to_code(:QueryCapitalFlowIntraday), do: 24
  defp cmd_to_code(:QueryCapitalFlowDistribution), do: 25
  defp cmd_to_code(:QuerySecurityCalcIndex), do: 26
  defp cmd_to_code(:QueryHistoryCandlestick), do: 27
  defp cmd_to_code(other) when is_atom(other), do: other
  defp cmd_to_code(other) when is_integer(other), do: other
end
