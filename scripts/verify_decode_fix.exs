# Live verification: confirm the response-gzip fix in
# Longbridge.Protocol.unpack/1 is working in production.
#
# Background: commit 9c8eaf3 added `decompress_body/2` to inflate
# gzipped response bodies when Header.gzip == true. The server has
# been gzipping responses that exceed its internal size threshold,
# regardless of the `gzip` flag we send on the request. Before the
# fix, large responses (5+ symbol quotes, option-chain strike info,
# etc.) hit Protox.decode!/2 as raw gzip bytes and raised
# Protox.DecodingError.
#
# Run with:
#   LONGBRIDGE_APP_KEY=... LONGBRIDGE_APP_SECRET=... LONGBRIDGE_TOKEN=... \
#     mix run scripts/verify_decode_fix.exs
#
# Each probe calls the live Longbridge server and prints whether the
# response decoded into the expected struct shape.

defmodule VerifyDecodeFix do
  @moduledoc false

  @methods [
    # `quote/2` with 5 symbols reliably crosses the server's gzip
    # threshold (verified by reverting decompress_body/2 — `quote`
    # raised `Protox.DecodingError: invalid wire type 7`).
    {:static_info, [["AAPL.US", "MSFT.US", "GOOG.US", "TSLA.US", "NVDA.US", "META.US", "AMZN.US"]]},
    {:quote, [["AAPL.US", "MSFT.US", "GOOG.US", "TSLA.US", "NVDA.US"]]},
    {:depth, ["AAPL.US"]},
    {:brokers, ["AAPL.US"]},
    {:option_chain_strike_info, ["AAPL.US", "20240119"]}
  ]

  def run do
    Logger.configure(level: :debug)
    config = build_config()

    {:ok, ctx} = Longbridge.QuoteContext.start_link(config)
    Process.sleep(2_000)

    results =
      Enum.map(@methods, fn {fun, args} ->
        result =
          try do
            apply(Longbridge.QuoteContext, fun, [ctx | List.wrap(args)])
          rescue
            e -> {:rescued, e.__struct__, Exception.message(e)}
          catch
            kind, value -> {:caught, kind, value}
          end

        {fun, result}
      end)

    print_table(results)

    failures = Enum.filter(results, fn {_f, r} -> not match?({:ok, _}, r) end)

    if failures == [] do
      IO.puts("\n\u2713 All 5 probes decoded successfully — the gzip fix in")
      IO.puts("  Longbridge.Protocol.unpack/1 (commit 9c8eaf3) is working.")
      System.halt(0)
    else
      IO.puts("\n\u2717 #{length(failures)} of 5 probes failed to decode.")
      System.halt(1)
    end
  end

  defp build_config do
    Longbridge.Config.new(
      token: System.fetch_env!("LONGBRIDGE_TOKEN"),
      app_key: System.fetch_env!("LONGBRIDGE_APP_KEY"),
      app_secret: System.fetch_env!("LONGBRIDGE_APP_SECRET"),
      quote_ws_url: "wss://openapi-quote.longbridge.com",
      heartbeat_interval: 15_000
    )
  end

  defp print_table(results) do
    header = String.pad_trailing("Method", 28) <> "Result"
    IO.puts(IO.ANSI.bright() <> header <> IO.ANSI.reset())
    IO.puts(String.duplicate("-", String.length(header)))

    Enum.each(results, fn {fun, result} ->
      formatted = format_result(result)
      IO.puts(String.pad_trailing("#{fun}", 28) <> formatted)
    end)
  end

  defp format_result({:ok, struct}) do
    fields = struct |> Map.from_struct() |> Map.drop([:__uf__])
    "ok \u2014 #{summarize(fields)}"
  end

  defp format_result({:rescued, mod, msg}) do
    "RAISED #{inspect(mod)}: #{String.slice(msg, 0, 60)}"
  end

  defp format_result({:caught, kind, value}) do
    "CAUGHT #{kind}: #{inspect(value)}"
  end

  defp format_result(other) do
    "? #{inspect(other)}"
  end

  defp summarize(fields) do
    fields
    |> Enum.map(fn {k, v} ->
      size =
        case v do
          list when is_list(list) -> "list(#{length(list)})"
          "" -> "\"\""
          nil -> "nil"
          other when is_binary(other) -> "string(#{byte_size(other)}B)"
          other -> inspect(other)
        end

      "#{k}: #{size}"
    end)
    |> Enum.join(", ")
  end
end

VerifyDecodeFix.run()
