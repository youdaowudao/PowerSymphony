defmodule SymphonyElixir.TestSupportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport

  describe "ex_unit_options/1" do
    test "returns empty options when no env is set" do
      assert TestSupport.ex_unit_options(%{}) == []
    end

    test "uses SYMPHONY_TEST_MAX_CASES when present" do
      assert TestSupport.ex_unit_options(%{"SYMPHONY_TEST_MAX_CASES" => "2"}) == [max_cases: 2]
    end

    test "falls back to MIX_TEST_MAX_CASES" do
      assert TestSupport.ex_unit_options(%{"MIX_TEST_MAX_CASES" => "3"}) == [max_cases: 3]
    end

    test "prefers SYMPHONY_TEST_MAX_CASES over MIX_TEST_MAX_CASES" do
      env = %{
        "SYMPHONY_TEST_MAX_CASES" => "4",
        "MIX_TEST_MAX_CASES" => "2"
      }

      assert TestSupport.ex_unit_options(env) == [max_cases: 4]
    end

    test "raises on invalid values" do
      for value <- ["0", "-1", "abc", "1.5", ""] do
        assert_raise ArgumentError, ~r/test max cases/, fn ->
          TestSupport.ex_unit_options(%{"SYMPHONY_TEST_MAX_CASES" => value})
        end
      end
    end
  end
end
