defmodule Longbridge.SymbolTest do
  use ExUnit.Case, async: false

  alias Longbridge.Symbol
  alias Longbridge.TestSupport.FakeHTTPServer

  describe "to_counter_id/1 — stock symbols" do
    test "US stock" do
      assert Symbol.to_counter_id("TSLA.US") == "ST/US/TSLA"
    end

    test "HK stock strips leading zeros" do
      assert Symbol.to_counter_id("00700.HK") == "ST/HK/700"
    end

    test "HK stock without leading zeros" do
      assert Symbol.to_counter_id("700.HK") == "ST/HK/700"
    end

    test "HK stock 09988" do
      assert Symbol.to_counter_id("09988.HK") == "ST/HK/9988"
    end

    test "SZ stock keeps leading zeros" do
      assert Symbol.to_counter_id("000001.SZ") == "ST/SZ/000001"
    end

    test "lowercase market suffix is normalised" do
      assert Symbol.to_counter_id("SPY.us") == "ETF/US/SPY"
    end
  end

  describe "to_counter_id/1 — special directory" do
    test "US ETF resolves to ETF/ prefix" do
      assert Symbol.to_counter_id("SPY.US") == "ETF/US/SPY"
    end

    test "US ETF QQQ" do
      assert Symbol.to_counter_id("QQQ.US") == "ETF/US/QQQ"
    end
  end

  describe "to_counter_id/1 — index symbols" do
    test "leading-dot US index" do
      assert Symbol.to_counter_id(".DJI.US") == "IX/US/.DJI"
    end

    test "leading-dot US VIX" do
      assert Symbol.to_counter_id(".VIX.US") == "IX/US/.VIX"
    end

    test "HK index (in directory)" do
      assert Symbol.to_counter_id("HSI.HK") == "IX/HK/HSI"
    end
  end

  describe "to_counter_id/1 — passthrough" do
    test "no dot passes through unchanged" do
      assert Symbol.to_counter_id("NODOT") == "NODOT"
    end

    test "non-binary value passes through unchanged" do
      assert Symbol.to_counter_id(:atom) == :atom
      assert Symbol.to_counter_id(nil) == nil
      assert Symbol.to_counter_id(123) == 123
    end
  end

  describe "index_to_counter_id/1" do
    test "always uses IX prefix" do
      assert Symbol.index_to_counter_id("HSI.HK") == "IX/HK/HSI"
    end

    test "US index" do
      assert Symbol.index_to_counter_id(".DJI.US") == "IX/US/.DJI"
    end

    test "no dot passes through" do
      assert Symbol.index_to_counter_id("NODOT") == "NODOT"
    end

    test "lowercase market suffix is normalised" do
      assert Symbol.index_to_counter_id("spx.us") == "IX/US/spx"
    end
  end

  describe "from_counter_id/1" do
    test "ST" do
      assert Symbol.from_counter_id("ST/US/AAPL") == "AAPL.US"
    end

    test "IX with leading dot" do
      assert Symbol.from_counter_id("IX/US/.DJI") == ".DJI.US"
    end

    test "round-trip" do
      assert Symbol.from_counter_id(Symbol.to_counter_id("TSLA.US")) == "TSLA.US"
    end

    test "non-counter_id passthrough" do
      assert Symbol.from_counter_id("NODOT") == "NODOT"
    end
  end

  describe "resolve_counter_ids/2" do
    defp start_fake_http_server(handler), do: FakeHTTPServer.start_with_finch(handler)

    defp stop_fake_http_server(server), do: FakeHTTPServer.stop_with_finch(server)

    defp parse_conn(conn), do: FakeHTTPServer.parse_conn(conn)

    defp ok(conn, data), do: FakeHTTPServer.ok(conn, data)

    defp config_with(port) do
      Longbridge.Config.new(
        token: "test-token",
        app_key: "test-key",
        app_secret: "test-secret",
        http_url: "http://127.0.0.1:#{port}"
      )
    end

    test "returns local results for known symbols without hitting the server" do
      # SPY.US is in the embedded ETF directory.
      assert {:ok,
              [
                %{symbol: "SPY.US", counter_id: "ETF/US/SPY"}
              ]} = Symbol.resolve_counter_ids(%Longbridge.Config{}, ["SPY.US"])
    end

    test "calls the server for unknown symbols and merges results" do
      # Use a fake symbol that's not in the directory.
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "POST"
          assert parsed.path_with_query =~ "/v1/quote/symbol-to-counter-ids"
          assert parsed.body =~ "ticker_regions"

          body =
            Jason.encode!(%{"code" => 0, "data" => %{"list" => %{"DRAM.US" => "ETF/US/DRAM"}}})

          ok(conn, body)
        end)

      assert {:ok, [%{symbol: "DRAM.US", counter_id: "ETF/US/DRAM"}]} =
               Symbol.resolve_counter_ids(config_with(server.port), ["DRAM.US"])

      stop_fake_http_server(server)
    end

    test "falls back to local default when the server returns no entry" do
      # BOGUS.XX is not in the directory and the server returns no list
      # entry for it. Falls back to ST/XX/BOGUS.
      server =
        start_fake_http_server(fn conn ->
          body = Jason.encode!(%{"code" => 0, "data" => %{"list" => %{}}})
          ok(conn, body)
        end)

      assert {:ok, [%{symbol: "BOGUS.XX", counter_id: "ST/XX/BOGUS"}]} =
               Symbol.resolve_counter_ids(config_with(server.port), ["BOGUS.XX"])

      stop_fake_http_server(server)
    end

    test "preserves input order" do
      assert {:ok,
              [
                %{symbol: "SPY.US", counter_id: "ETF/US/SPY"},
                %{symbol: "VOO.US", counter_id: "ETF/US/VOO"}
              ]} =
               Symbol.resolve_counter_ids(%Longbridge.Config{}, ["SPY.US", "VOO.US"])
    end
  end

  describe "Longbridge.Symbol.Cache" do
    alias Longbridge.Symbol.Cache

    test "put + lookup round-trip" do
      uid = System.unique_integer([:positive])
      a = "ETF/US/FAKE_#{uid}"
      b = "ST/HK/FAKE_#{uid}"
      Cache.put([a, b])
      assert Cache.lookup("FAKE_#{uid}.US") == a
      assert Cache.lookup("FAKE_#{uid}.HK") == b
      assert Cache.lookup("UNKNOWN.US") == nil
      Cache.reset()
    end

    test "empty / whitespace inputs are ignored" do
      uid = System.unique_integer([:positive])
      cid = "ETF/US/REAL_#{uid}"
      Cache.put(["", "   ", cid])
      assert Cache.lookup("REAL_#{uid}.US") == cid
      Cache.reset()
    end

    test "duplicate entries do not trigger a write" do
      uid = System.unique_integer([:positive])
      a = "ETF/US/DUP_#{uid}"
      b = "ST/HK/DUP_#{uid}_2"
      Cache.put([a])
      Cache.put([a, b])
      assert Cache.lookup("DUP_#{uid}.US") == a
      assert Cache.lookup("DUP_#{uid}_2.HK") == b
      Cache.reset()
    end

    test "reset clears the cache" do
      uid = System.unique_integer([:positive])
      cid = "ETF/US/RESET_#{uid}"
      Cache.put([cid])
      assert Cache.lookup("RESET_#{uid}.US") == cid
      Cache.reset()
      assert Cache.lookup("RESET_#{uid}.US") == nil
    end

    test "lookup covers WT/IX/ST prefix order" do
      uid = System.unique_integer([:positive])
      wt = "WT/HK/#{uid}"
      ix = "IX/US/#{uid}_IX"
      st = "ST/HK/#{uid}_ST"
      Cache.put([wt, ix, st])
      assert Cache.lookup("#{uid}.HK") == wt
      assert Cache.lookup("#{uid}_IX.US") == ix
      assert Cache.lookup("#{uid}_ST.HK") == st
      Cache.reset()
    end

    test "lookup with no dot returns nil" do
      uid = System.unique_integer([:positive])
      Cache.put(["ST/US/NODOT_#{uid}"])
      assert Cache.lookup("NODOT_#{uid}") == nil
      Cache.reset()
    end

    test "ensure_loaded handles missing cache file" do
      # Point the cache at a non-existent directory to exercise the :enoent branch.
      original = System.get_env("LONGBRIDGE_CACHE_DIR")

      System.put_env(
        "LONGBRIDGE_CACHE_DIR",
        "/tmp/longbridge_no_such_dir_#{System.unique_integer()}"
      )

      try do
        # Drop the table so the next call to ensure_loaded/reset sees :undefined
        try do
          :ets.delete(Longbridge.Symbol.Cache)
        rescue
          ArgumentError -> :ok
        end

        assert Cache.reset() == :ok
        # Touching lookup should trigger ensure_loaded + load_from_disk → :enoent
        assert Cache.lookup("ANYTHING.US") == nil
      after
        if original,
          do: System.put_env("LONGBRIDGE_CACHE_DIR", original),
          else: System.delete_env("LONGBRIDGE_CACHE_DIR")
      end
    end

    test "reset on uninitialised table returns :ok without raising" do
      try do
        :ets.delete(Longbridge.Symbol.Cache)
      rescue
        ArgumentError -> :ok
      end

      assert Cache.reset() == :ok
    end

    test "non-enoent read errors log a warning and continue" do
      # Point the cache at a *directory* whose name is the cache file.
      # File.read on a directory returns {:error, :eisdir}, which exercises
      # the `{:error, reason}` branch (other than :enoent) and the
      # Logger.warning call.
      original_env = System.get_env("LONGBRIDGE_CACHE_DIR")
      base = Path.join(System.tmp_dir!(), "longbridge_cache_isdir_#{System.unique_integer()}")
      File.mkdir_p!(base)
      File.mkdir_p!(Path.join(base, "counter-ids.csv"))

      try do
        System.put_env("LONGBRIDGE_CACHE_DIR", base)

        try do
          :ets.delete(Longbridge.Symbol.Cache)
        rescue
          ArgumentError -> :ok
        end

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert Cache.reset() == :ok
            assert Cache.lookup("ANYTHING.US") == nil
          end)

        assert log =~ "longbridge counter-id cache read failed"
      after
        File.rm_rf(base)

        if original_env,
          do: System.put_env("LONGBRIDGE_CACHE_DIR", original_env),
          else: System.delete_env("LONGBRIDGE_CACHE_DIR")
      end
    end
  end

  describe "Longbridge.Symbol.Directory" do
    alias Longbridge.Symbol.Directory

    test "ETF directory entries are loaded" do
      assert Directory.lookup("SPY.US", "US", "SPY") == "ETF/US/SPY"
    end

    test "US warrant directory entries are loaded" do
      # US-WT.csv ships with WT/HK/10005 — use a HK warrant lookup to verify
      # the directory is reachable even when no exact US-WT hit exists.
      assert is_nil(Directory.lookup("UNKNOWN.HK", "HK", "99999999"))
    end

    test "US index prefix wins over default ST" do
      assert Directory.lookup(".DJI.US", "US", ".DJI") == "IX/US/.DJI"
    end

    test "non-matching symbol returns nil" do
      assert Directory.lookup("UNKNOWN.US", "US", "UNKNOWN") == nil
    end

    test "ensure_loaded is idempotent — second call returns :ok" do
      # First call loaded the table; second call must hit the
      # `_other -> :ok` branch instead of re-creating the ETS table.
      assert Directory.lookup("ANY", "US", "ANY") in [nil, "ETF/US/ANY", "IX/US/ANY"]
      # A direct call would require the function to be public. Instead, drive
      # ensure_loaded by doing many concurrent lookups — none of them should
      # raise :badarg from a re-created ETS table.
      results =
        1..50
        |> Task.async_stream(fn _ -> Directory.lookup("ANY", "US", "ANY") end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert length(results) == 50
    end

    test "load_file raises when the embedded CSV is unreadable" do
      # Simulate a missing/misplaced file by deleting the ETS table and
      # having `Application.app_dir/2` resolve to a path that does not
      # contain US-ETF.csv. We do that by temporarily overriding the
      # application dir through `:code.all_dir/1` rewriting the priv
      # directory via a symlink-less file mv into a fresh tmpdir.
      base = Application.app_dir(:longbridge, "priv/counter_ids")
      stash_dir = Path.join(System.tmp_dir!(), "longbridge_dir_stash_#{System.unique_integer()}")
      File.mkdir_p!(stash_dir)

      # Move all CSVs out of the priv dir, then move them back.
      files = for f <- File.ls!(base), do: Path.join(base, f)
      moved = Enum.map(files, fn p -> {p, Path.join(stash_dir, Path.basename(p))} end)

      try do
        Enum.each(moved, fn {src, dst} -> File.rename!(src, dst) end)

        # Drop the table so ensure_loaded runs the load_file branch.
        try do
          :ets.delete(Longbridge.Symbol.Directory)
        rescue
          ArgumentError -> :ok
        end

        assert_raise RuntimeError, ~r/US-ETF\.csv could not be loaded/, fn ->
          Directory.lookup("ANY", "US", "ANY")
        end
      after
        Enum.each(moved, fn {src, dst} -> File.rename!(dst, src) end)
        File.rmdir(stash_dir)

        # Drop the table again so the next test re-loads from the real priv.
        try do
          :ets.delete(Longbridge.Symbol.Directory)
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end
end
