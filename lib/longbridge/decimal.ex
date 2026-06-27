defmodule Longbridge.Decimal do
  @moduledoc """
  Optional helpers for converting Longbridge wire-format strings
  to numeric values.

  Longbridge returns monetary and quantitative fields as strings
  (e.g. `"0.0723"`, `"3241500000000"`). This module provides
  helpers to convert those strings to a numeric type without
  pulling in the `:decimal` package as a hard dependency.

  Most callers will want to use `Decimal` from the `:decimal`
  package for exact arithmetic on monetary values. If you don't
  depend on `:decimal`, `parse_number/1` returns either an
  integer or a float depending on whether the string contains
  a decimal point.

  ## Usage with `:decimal`

      {:ok, config} = Longbridge.OAuth.load_token(client_id)
      {:ok, %{price_close: p}} = Longbridge.FundamentalContext.valuation_comparison(config, "AAPL.US", "USD")
      dec = Longbridge.Decimal.to_bigdecimal(p)
      Float.round(Decimal.to_float(dec), 2)

  ## Usage without `:decimal`

      price = Longbridge.Decimal.parse_number("0.0723")
      # => 0.0723

  To use the `:decimal`-backed helpers, add `{:decimal, "~> 2.0 or ~> 3.0"}`
  to your `mix.exs` dependencies.
  """

  @doc """
  Parses a wire-format numeric string.

  Returns an integer if the string contains no decimal point, or
  a float otherwise. Returns `nil` for empty strings or `nil`.

  ## Examples

      iex> Longbridge.Decimal.parse_number("100")
      100
      iex> Longbridge.Decimal.parse_number("3.14")
      3.14
      iex> Longbridge.Decimal.parse_number("")
      nil
  """
  @spec parse_number(String.t() | nil) :: number() | nil
  def parse_number(nil), do: nil
  def parse_number(""), do: nil

  def parse_number(<<?-, rest::binary>>) do
    case parse_number(rest) do
      nil -> nil
      n -> -n
    end
  end

  def parse_number(<<?., rest::binary>>) do
    case parse_number("0." <> rest) do
      n when is_number(n) -> n
      _ -> nil
    end
  end

  def parse_number(s) when is_binary(s) do
    if String.contains?(s, ".") do
      case Float.parse(s) do
        {f, ""} -> f
        _ -> nil
      end
    else
      case Integer.parse(s) do
        {i, ""} -> i
        _ -> nil
      end
    end
  end

  @doc """
  Parses a wire-format numeric string as a `Decimal`.

  Requires the `:decimal` package as a dependency in your app.
  Returns `nil` for empty/nil inputs.

  If `:decimal` is not loaded, raises `ArgumentError` at call time
  with a hint to add the dependency.

  ## Examples

      iex> Longbridge.Decimal.to_bigdecimal("3.14") |> Decimal.to_string()
      "3.14"
  """
  @spec to_bigdecimal(String.t() | nil) :: struct() | nil
  def to_bigdecimal(nil), do: nil
  def to_bigdecimal(""), do: nil

  def to_bigdecimal(s) when is_binary(s) do
    ensure_decimal!()
    d(:new, [s])
  end

  @doc """
  Sums a list of wire-format numeric strings into a single
  `Decimal`. `nil` and empty strings are treated as zero.

  Requires the `:decimal` package in your app.
  """
  @spec sum_bigdecimal([String.t() | nil | number()]) :: struct()
  def sum_bigdecimal(values) when is_list(values) do
    ensure_decimal!()
    zero = d(:new, [0])

    Enum.reduce(values, zero, fn
      nil, acc -> acc
      "", acc -> acc
      v, acc when is_binary(v) -> d(:add, [acc, d(:new, [v])])
      v, acc when is_integer(v) or is_float(v) -> d(:add, [acc, d(:new, [v])])
    end)
  end

  defp ensure_decimal! do
    if Code.ensure_loaded?(Decimal) and function_exported?(Decimal, :new, 1) do
      :ok
    else
      raise ArgumentError,
            "the :decimal package must be added as a dependency " <>
              "to use Longbridge.Decimal.to_bigdecimal/1 and sum_bigdecimal/1"
    end
  end

  # Indirection through apply/3 silences the "module not loaded"
  # compile-time warning when :decimal is not a direct dep. At
  # call time, ensure_decimal!/0 guarantees the module is loaded.
  defp d(fun, args), do: apply(Decimal, fun, args)
end
