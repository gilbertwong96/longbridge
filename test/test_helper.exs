# The WS reconnect and token-refresh failure-path tests deliberately
# trigger library log lines, flooding `mix test` output. Silence the
# info/debug chatter here (capture_log-based tests still work because
# warning messages pass the level check).
Logger.configure(level: :warning)

ExUnit.start()
