defmodule Longbridge.Connection.Session do
  @moduledoc false
  # Transport-agnostic session logic shared by `Longbridge.Connection` (TCP)
  # and `Longbridge.WSConnection` (WebSocket). Pure functions only — no
  # socket I/O. Both transport modules delegate here for protocol-level
  # behaviour (dispatch, reconnect, idle, broadcast, etc.).

  require Logger

  alias Longbridge.Protocol

  @reconnect_initial_delay 1_000
  @reconnect_max_delay 30_000
  @max_reconnect_attempts 10
  @reconnect_jitter 500

  @doc false
  def next_request_id(state), do: state.request_id + 1

  @doc false
  # Runs the auth flow once, and on `{:auth_failed, _}` attempts a
  # token refresh and retries. `do_auth_fn` is the transport-specific
  # auth implementation (e.g. `do_auth/1` in the calling module).
  def do_auth_with_retry(state, do_auth_fn) do
    case do_auth_fn.(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, {:auth_failed, _} = reason} ->
        if state.config.app_key && state.config.app_secret do
          Logger.info(
            "[Longbridge.#{state.type}] Auth failed (#{inspect(reason)}), attempting token refresh..."
          )

          refresh_and_retry_auth(state, do_auth_fn)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_and_retry_auth(state, do_auth_fn) do
    result =
      try do
        state.refresh_token_fn.(state.config)
      rescue
        exception in [ArgumentError, MatchError, RuntimeError] ->
          {:error, {:refresh_exception, exception}}
      end

    case result do
      {:ok, new_config} ->
        Logger.info("[Longbridge.#{state.type}] Token refreshed, retrying auth...")
        state = %{state | config: new_config}
        do_auth_fn.(state)

      {:error, refresh_reason} ->
        Logger.warning(
          "[Longbridge.#{state.type}] Token refresh failed: #{inspect(refresh_reason)}"
        )

        {:error, {:auth_failed_and_refresh_failed, refresh_reason}}
    end
  end

  @doc false
  def dispatch_response(state, header, body) do
    req_id = header.request_id

    case Map.pop(state.pending, req_id) do
      {%{from: from, ref: ref}, state} ->
        _ = Process.cancel_timer(ref)

        if header.status_code == Protocol.status_success() do
          GenServer.reply(from, {:ok, body, req_id})
        else
          GenServer.reply(from, {:error, {:server_error, header.status_code, body}})
        end

        state

      {nil, state} ->
        Logger.warning("[Longbridge.#{state.type}] Unexpected response for req_id: #{req_id}")
        state
    end
  end

  @doc false
  def dispatch_push(state, header, body) do
    broadcast(state, {:push, header.cmd_code, body})
    state
  end

  @doc false
  def broadcast(state, message) do
    for pid <- state.subscribers, do: send(pid, {:longbridge, self(), message})
    :ok
  end

  @doc false
  def fail_pending_requests(state, reason) do
    Enum.each(state.pending, fn {_req_id, %{from: from, ref: ref}} ->
      _ = if(ref, do: Process.cancel_timer(ref))
      GenServer.reply(from, {:error, {:disconnected, reason}})
    end)

    :ok
  end

  @doc false
  def schedule_reconnect(state, _reason) do
    if state.reconnect_attempts >= @max_reconnect_attempts do
      Logger.error(
        "[Longbridge.#{state.type}] Giving up after #{@max_reconnect_attempts} reconnect attempts"
      )

      broadcast(state, :reconnect_exhausted)
      state
    else
      delay = backoff_delay(state.reconnect_attempts)
      timer = Process.send_after(self(), :reconnect, delay)
      state = %{state | reconnect_timer: timer, reconnect_attempts: state.reconnect_attempts + 1}

      Logger.info(
        "[Longbridge.#{state.type}] Reconnecting in #{div(delay, 1000)}s " <>
          "(attempt #{state.reconnect_attempts}/#{@max_reconnect_attempts})"
      )

      state
    end
  end

  defp backoff_delay(attempts) do
    base = @reconnect_initial_delay * :math.pow(2, attempts)
    capped = min(base, @reconnect_max_delay)
    jitter = :rand.uniform(@reconnect_jitter)
    round(capped + jitter)
  end

  @doc false
  def schedule_idle_timer(%{config: %{idle_timeout: timeout}} = state) when timeout > 0 do
    _ = if(state.idle_timer, do: Process.cancel_timer(state.idle_timer))
    timer = Process.send_after(self(), :idle_timeout, timeout)
    %{state | idle_timer: timer}
  end

  def schedule_idle_timer(state), do: state

  @doc false
  def cancel_idle_timer(state) do
    if state.idle_timer do
      _ = Process.cancel_timer(state.idle_timer)
      %{state | idle_timer: nil}
    else
      state
    end
  end

  @doc false
  def cancel_reconnect_timer(%{reconnect_timer: nil}), do: :ok

  def cancel_reconnect_timer(%{reconnect_timer: ref}) do
    _ = Process.cancel_timer(ref)
    :ok
  end
end
