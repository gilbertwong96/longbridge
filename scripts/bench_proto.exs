# Local CPU microbenchmarks for the SDK's message and framing paths.
# No network access — every workload runs against in-memory fixtures.
#
# Why this exists: the v0.3.0 release moves protox 2.0.9 -> 2.1.0 and
# regenerates lib/longbridge/_protos.ex, which changes the encoder and decoder
# in both the runtime library and the generated code. Upstream reports ~40%
# less memory / ~37% fewer reductions encoding and ~30% less of both decoding.
# This script runs the same workloads on this SDK's own message types so that
# claim can be checked locally.
#
# One tree:
#   mix run scripts/bench_proto.exs > /tmp/bench-new.json
#
# Two trees (this is where the v0.3.0 release numbers come from):
#   git worktree add --detach /tmp/lb-baseline v0.2.1
#   cp scripts/bench_proto.exs /tmp/lb-baseline/scripts/
#   cd /tmp/lb-baseline && mix deps.get && mix run scripts/bench_proto.exs > /tmp/bench-old.json
#   jq -r '.results[] | [.name, .ns_per_op, .reductions_per_op, .words_per_op] | @tsv' /tmp/bench-*.json
#
# Every workload reports a checksum of the value it produced. Equal checksums
# across trees mean both runs measured identical inputs and outputs, so a
# difference in the timings is attributable to the code being measured.
#
# Reading the numbers: ns_per_op is a median over repetitions of calibrated
# batches, so it is the noisy column on a machine that is also doing other
# work. reductions_per_op and words_per_op are deterministic for a given
# workload and are the more trustworthy signal.

defmodule BenchProto do
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol
  alias Longbridge.Protocol.Header
  alias Longbridge.Quote.V1, as: Q

  @min_batch_us 20_000
  @reps 7
  @warmup_ops 200
  @depth_levels 50

  # ── measurement ──────────────────────────────────────────

  defp loop(_fun, 0), do: :ok

  defp loop(fun, n) do
    fun.()
    loop(fun, n - 1)
  end

  defp calibrate(fun, min_us, n \\ 1) do
    {us, :ok} = :timer.tc(fn -> loop(fun, n) end)

    if us >= min_us do
      n
    else
      calibrate(fun, min_us, n * 2)
    end
  end

  defp sample(fun, ops) do
    :erlang.garbage_collect()
    {_gc0, words0, _} = :erlang.statistics(:garbage_collection)
    {:reductions, red0} = Process.info(self(), :reductions)

    {us, :ok} = :timer.tc(fn -> loop(fun, ops) end)

    {:reductions, red1} = Process.info(self(), :reductions)
    :erlang.garbage_collect()
    {_gc1, words1, _} = :erlang.statistics(:garbage_collection)

    %{
      ns_per_op: us * 1000 / ops,
      reductions_per_op: (red1 - red0) / ops,
      words_per_op: (words1 - words0) / ops
    }
  end

  defp median(numbers) do
    sorted = Enum.sort(numbers)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp measure(name, fun, checksum) do
    loop(fun, @warmup_ops)
    ops = calibrate(fun, @min_batch_us)
    samples = for _ <- 1..@reps, do: sample(fun, ops)

    %{
      name: name,
      ops_per_batch: ops,
      ns_per_op: samples |> Enum.map(& &1.ns_per_op) |> median() |> Float.round(1),
      reductions_per_op: samples |> Enum.map(& &1.reductions_per_op) |> median() |> Float.round(1),
      words_per_op: samples |> Enum.map(& &1.words_per_op) |> median() |> Float.round(1),
      checksum: checksum
    }
  end

  # ── fixtures ─────────────────────────────────────────────

  defp encode(msg) do
    {:ok, iodata, _size} = Protox.encode(msg)
    IO.iodata_to_binary(iodata)
  end

  defp pre_post_quote do
    %Q.PrePostQuote{
      last_done: "612.500",
      high: "618.000",
      low: "609.500",
      prev_close: "610.000",
      timestamp: 1_760_000_000,
      volume: 1_234_567,
      turnover: "755600000"
    }
  end

  defp security_quote do
    %Q.SecurityQuote{
      symbol: "700.HK",
      last_done: "612.500",
      prev_close: "610.000",
      open: "611.000",
      high: "618.000",
      low: "609.500",
      timestamp: 1_760_000_000,
      volume: 12_345_678,
      turnover: "7556000000",
      trade_status: :NORMAL,
      pre_market_quote: pre_post_quote(),
      post_market_quote: pre_post_quote(),
      over_night_quote: pre_post_quote()
    }
  end

  defp security_depth_response do
    levels =
      for i <- 1..@depth_levels do
        %Q.Depth{
          position: i,
          price: "611." <> String.pad_leading(Integer.to_string(rem(i * 7, 1000)), 3, "0"),
          volume: i * 100,
          order_num: i
        }
      end

    %Q.SecurityDepthResponse{symbol: "700.HK", ask: levels, bid: levels}
  end

  defp auth_request do
    %Ctrl.AuthRequest{token: "0123456789abcdef0123456789abcdef", metadata: %{"client" => "bench"}}
  end

  # ── workloads ────────────────────────────────────────────

  defp workloads do
    auth = auth_request()
    quote = security_quote()
    depth = security_depth_response()

    auth_bytes = encode(auth)
    quote_bytes = encode(quote)
    depth_bytes = encode(depth)
    gzipped_depth = :zlib.gzip(depth_bytes)

    # Header.pack/1 validates body_length, and Protocol.pack/2 overwrites it,
    # so the fixtures carry a concrete value and the framer recomputes it.
    request_header = %Header{
      type: :request,
      verify: false,
      gzip: false,
      cmd_code: 1,
      request_id: 1,
      timeout: 5_000,
      body_length: 0
    }

    gzip_response_header = %Header{
      type: :response,
      verify: false,
      gzip: true,
      cmd_code: 1,
      request_id: 1,
      status_code: 0,
      body_length: 0
    }

    round_trip = fn header, body ->
      packet = Protocol.pack(header, body) |> IO.iodata_to_binary()
      {:ok, _header, unpacked, ""} = Protocol.unpack(packet)
      unpacked
    end

    header_round_trip = fn ->
      binary = Header.pack(request_header) |> IO.iodata_to_binary()
      {:ok, header, ""} = Header.unpack(binary)
      header
    end

    [
      {"encode AuthRequest (3 fields)", fn -> encode(auth) end, :erlang.phash2(auth_bytes)},
      {"encode SecurityQuote (14 fields, 3 nested)", fn -> encode(quote) end,
       :erlang.phash2(quote_bytes)},
      {"encode SecurityDepthResponse (2 x #{@depth_levels} levels)",
       fn -> encode(depth) end, :erlang.phash2(depth_bytes)},
      {"decode SecurityQuote", fn -> Protox.decode!(quote_bytes, Q.SecurityQuote) end,
       :erlang.phash2(Protox.decode!(quote_bytes, Q.SecurityQuote))},
      {"decode SecurityDepthResponse (2 x #{@depth_levels} levels)",
       fn -> Protox.decode!(depth_bytes, Q.SecurityDepthResponse) end,
       :erlang.phash2(Protox.decode!(depth_bytes, Q.SecurityDepthResponse))},
      {"Header.pack + unpack (11-byte request)", header_round_trip,
       :erlang.phash2(header_round_trip.())},
      {"Protocol round trip (request, quote body)", fn -> round_trip.(request_header, quote_bytes) end,
       :erlang.phash2(round_trip.(request_header, quote_bytes))},
      {"Protocol round trip (response, gzipped depth body)",
       fn -> round_trip.(gzip_response_header, gzipped_depth) end,
       :erlang.phash2(round_trip.(gzip_response_header, gzipped_depth))}
    ]
  end

  # ── entry point ──────────────────────────────────────────

  def run do
    meta = %{
      longbridge: to_string(Application.spec(:longbridge, :vsn)),
      protox: to_string(Application.spec(:protox, :vsn)),
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online(),
      reps: @reps,
      depth_levels: @depth_levels
    }

    results =
      workloads()
      |> Enum.map(fn {name, fun, checksum} -> measure(name, fun, checksum) end)

    # Compact JSON on stdout, so runs can be diffed and read back with jq:
    #   jq -r '.results[] | [.name, .ns_per_op, .reductions_per_op, .words_per_op] | @tsv' out.json
    # Elixir's JSON module has no pretty-print option (its 2-arity form takes a
    # custom encoder), so the script stays quiet and lets jq do the formatting.
    IO.puts(JSON.encode!(%{meta: meta, results: results}))
  end
end

BenchProto.run()
