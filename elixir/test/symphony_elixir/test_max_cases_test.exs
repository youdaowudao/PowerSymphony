defmodule SymphonyElixir.TestMaxCasesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestMaxCases

  test "未设置环境变量时不覆盖 ExUnit 默认并发" do
    assert TestMaxCases.ex_unit_options(nil) == []
  end

  test "设置正整数时生成 max_cases 选项" do
    assert TestMaxCases.ex_unit_options("2") == [max_cases: 2]
    assert TestMaxCases.ex_unit_options(" 3 ") == [max_cases: 3]
  end

  test "从环境变量读取 max_cases" do
    previous = System.get_env("SYMPHONY_TEST_MAX_CASES")
    on_exit(fn -> SymphonyElixir.TestSupport.restore_env("SYMPHONY_TEST_MAX_CASES", previous) end)

    System.put_env("SYMPHONY_TEST_MAX_CASES", "2")

    assert TestMaxCases.ex_unit_options_from_env() == [max_cases: 2]
  end

  test "非法值时报清晰错误" do
    assert_raise ArgumentError, ~r/SYMPHONY_TEST_MAX_CASES must be a positive integer/, fn ->
      TestMaxCases.ex_unit_options("0")
    end

    assert_raise ArgumentError, ~r/SYMPHONY_TEST_MAX_CASES must be a positive integer/, fn ->
      TestMaxCases.ex_unit_options("abc")
    end

    assert_raise ArgumentError, ~r/SYMPHONY_TEST_MAX_CASES must be a positive integer/, fn ->
      TestMaxCases.ex_unit_options(" ")
    end
  end
end
