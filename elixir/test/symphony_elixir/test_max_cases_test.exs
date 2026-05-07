defmodule SymphonyElixir.TestMaxCasesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport

  test "未设置环境变量时不覆盖 ExUnit 默认并发" do
    assert TestSupport.ex_unit_options(%{}) == []
  end

  test "设置 SYMPHONY_TEST_MAX_CASES 时生成 max_cases 选项" do
    assert TestSupport.ex_unit_options(%{"SYMPHONY_TEST_MAX_CASES" => "2"}) == [max_cases: 2]
  end

  test "未设置 SYMPHONY_TEST_MAX_CASES 时回退到 MIX_TEST_MAX_CASES" do
    assert TestSupport.ex_unit_options(%{"MIX_TEST_MAX_CASES" => "3"}) == [max_cases: 3]
  end

  test "默认从系统环境读取并优先使用 SYMPHONY_TEST_MAX_CASES" do
    previous_symphony = System.get_env("SYMPHONY_TEST_MAX_CASES")
    previous_mix = System.get_env("MIX_TEST_MAX_CASES")

    on_exit(fn ->
      SymphonyElixir.TestSupport.restore_env("SYMPHONY_TEST_MAX_CASES", previous_symphony)
      SymphonyElixir.TestSupport.restore_env("MIX_TEST_MAX_CASES", previous_mix)
    end)

    System.put_env("SYMPHONY_TEST_MAX_CASES", "4")
    System.put_env("MIX_TEST_MAX_CASES", "2")

    assert TestSupport.ex_unit_options() == [max_cases: 4]
  end

  test "非法值时报清晰错误" do
    for value <- ["0", "-1", "abc", " 3 ", " "] do
      assert_raise ArgumentError, ~r/test max cases must be a positive integer, got:/, fn ->
        TestSupport.ex_unit_options(%{"SYMPHONY_TEST_MAX_CASES" => value})
      end
    end
  end
end
