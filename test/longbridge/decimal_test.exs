defmodule Longbridge.DecimalTest do
  use ExUnit.Case, async: true

  alias Longbridge.Decimal

  defp decimal_loaded?,
    do: Code.ensure_loaded?(Decimal) and function_exported?(Decimal, :new, 1)

  describe "parse_number/1" do
    test "parses integer strings" do
      assert Decimal.parse_number("100") == 100
      assert Decimal.parse_number("0") == 0
      assert Decimal.parse_number("-42") == -42
      assert Decimal.parse_number("3241500000000") == 3_241_500_000_000
    end

    test "parses float strings" do
      assert Decimal.parse_number("3.14") == 3.14
      assert Decimal.parse_number("0.0723") == 0.0723
      assert Decimal.parse_number("-1.5") == -1.5
    end

    test "returns nil for empty and nil" do
      assert Decimal.parse_number("") == nil
      assert Decimal.parse_number(nil) == nil
    end

    test "returns nil for malformed strings" do
      assert Decimal.parse_number("not a number") == nil
      assert Decimal.parse_number("3.14.15") == nil
      assert Decimal.parse_number("abc123") == nil
    end

    test "handles leading sign" do
      assert Decimal.parse_number("+5") == 5
      assert Decimal.parse_number("+3.14") == 3.14
    end

    test "handles leading dot" do
      assert Decimal.parse_number(".5") == 0.5
    end

    test "returns nil for partial parses" do
      # "3abc" parses as 3 but the trailing garbage should not be
      # silently dropped. parse_number requires the whole string
      # to be numeric.
      assert Decimal.parse_number("3abc") == nil
    end
  end

  describe "to_bigdecimal/1" do
    test "returns nil for nil and empty" do
      assert Decimal.to_bigdecimal(nil) == nil
      assert Decimal.to_bigdecimal("") == nil
    end

    test "parses a numeric string when :decimal is loaded" do
      if decimal_loaded?() do
        result = Decimal.to_bigdecimal("3.14")
        assert apply(Decimal, :to_string, [result]) == "3.14"
      else
        assert_raise ArgumentError, ~r/:decimal/, fn ->
          Decimal.to_bigdecimal("3.14")
        end
      end
    end
  end

  describe "sum_bigdecimal/1" do
    test "sums a list of strings" do
      if decimal_loaded?() do
        result = Decimal.sum_bigdecimal(["1.5", "2.5"])
        assert apply(Decimal, :to_string, [result]) == "4.0"
      else
        assert_raise ArgumentError, ~r/:decimal/, fn ->
          Decimal.sum_bigdecimal(["1.5", "2.5"])
        end
      end
    end

    test "treats nil and empty as zero" do
      if decimal_loaded?() do
        assert apply(Decimal, :to_string, [Decimal.sum_bigdecimal([nil, "", "1.0"])]) == "1.0"
        assert apply(Decimal, :to_string, [Decimal.sum_bigdecimal([])]) == "0"
        assert apply(Decimal, :to_string, [Decimal.sum_bigdecimal([nil, nil])]) == "0"
      else
        assert_raise ArgumentError, fn ->
          Decimal.sum_bigdecimal(["1.0"])
        end
      end
    end

    test "accepts mixed strings and numbers" do
      if decimal_loaded?() do
        result = Decimal.sum_bigdecimal(["1.5", 2, 0.5, nil, ""])
        assert apply(Decimal, :to_string, [result]) == "4.0"
      end
    end
  end
end
