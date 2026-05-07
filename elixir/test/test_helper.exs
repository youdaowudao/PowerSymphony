defmodule SymphonyElixir.TestMaxCases do
  @env_var "SYMPHONY_TEST_MAX_CASES"

  def ex_unit_options(value) do
    case value do
      nil ->
        []

      raw ->
        trimmed = String.trim(raw)

        case Integer.parse(trimmed) do
          {max_cases, ""} when max_cases > 0 ->
            [max_cases: max_cases]

          _ ->
            raise ArgumentError,
                  "#{@env_var} must be a positive integer, got: #{inspect(raw)}"
        end
    end
  end

  def ex_unit_options_from_env do
    @env_var
    |> System.get_env()
    |> ex_unit_options()
  end
end

ExUnit.start(SymphonyElixir.TestMaxCases.ex_unit_options_from_env())
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
