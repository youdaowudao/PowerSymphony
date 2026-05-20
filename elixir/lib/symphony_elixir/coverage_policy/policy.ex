defmodule SymphonyElixir.CoveragePolicy.Policy do
  @moduledoc false

  @app :symphony_elixir
  @config_key :coverage_policy

  @spec config() :: keyword()
  def config do
    Application.fetch_env!(@app, @config_key)
  end

  @spec tiers() :: map()
  def tiers do
    config()[:tiers] || %{}
  end

  @spec thresholds() :: map()
  def thresholds do
    config()[:thresholds] || %{}
  end

  @spec diff_coverage() :: map()
  def diff_coverage do
    config()[:diff_coverage] || %{}
  end

  @spec ignore_audit() :: [map()]
  def ignore_audit do
    config()[:ignore_audit] || []
  end

  @spec ignore_modules() :: [module() | Regex.t()]
  def ignore_modules do
    Mix.Project.config()
    |> Keyword.fetch!(:test_coverage)
    |> Keyword.get(:ignore_modules, [])
  end

  @spec validate_ignore_audit!([map()]) :: :ok
  def validate_ignore_audit!(entries) do
    ignored_modules = MapSet.new(ignore_modules())
    audit_modules = entries |> Enum.map(&Map.fetch!(&1, :module)) |> MapSet.new()

    assert_no_missing_ignore_audit!(ignored_modules, audit_modules)
    assert_no_extra_ignore_audit!(ignored_modules, audit_modules)
    Enum.each(entries, &assert_complete_ignore_audit_entry!/1)

    :ok
  end

  @spec resolve_base_ref(map(), String.t() | nil) :: {:ok, String.t()} | {:skip, :missing_base_ref}
  def resolve_base_ref(policy, nil) do
    mode = policy[:diff_coverage][:mode]

    case mode do
      :skip_without_base -> {:skip, :missing_base_ref}
      :enforce -> raise ArgumentError, "base ref is required when diff coverage mode is :enforce"
      other -> raise ArgumentError, "unsupported diff coverage mode: #{inspect(other)}"
    end
  end

  def resolve_base_ref(_policy, base_ref) when is_binary(base_ref) and base_ref != "" do
    {:ok, base_ref}
  end

  @spec module_policy(module()) :: %{
          tier: atom(),
          enforce_threshold?: boolean(),
          threshold: float() | nil,
          target_threshold: float()
        }
  def module_policy(module) do
    tier_config = Map.get(tiers(), module)
    threshold_map = thresholds()

    case tier_config do
      %{tier: tier, current_baseline: baseline} ->
        %{
          tier: tier,
          enforce_threshold?: true,
          threshold: as_float(baseline),
          target_threshold: as_float(Map.fetch!(threshold_map, tier))
        }

      nil ->
        target_threshold = as_float(Map.fetch!(threshold_map, :c))

        %{
          tier: :c,
          enforce_threshold?: false,
          threshold: nil,
          target_threshold: target_threshold
        }
    end
  end

  defp assert_no_missing_ignore_audit!(ignored_modules, audit_modules) do
    missing =
      ignored_modules
      |> MapSet.difference(audit_modules)
      |> MapSet.to_list()
      |> Enum.sort()

    if missing != [] do
      raise ArgumentError,
            "missing ignore audit metadata for ignored modules: #{inspect(missing)}"
    end
  end

  defp assert_no_extra_ignore_audit!(ignored_modules, audit_modules) do
    extra =
      audit_modules
      |> MapSet.difference(ignored_modules)
      |> MapSet.to_list()
      |> Enum.sort()

    if extra != [] do
      raise ArgumentError,
            "ignore audit contains modules not present in mix.exs ignore_modules: #{inspect(extra)}"
    end
  end

  defp assert_complete_ignore_audit_entry!(entry) do
    Enum.each([:module, :reason, :test_target, :review_after], fn key ->
      if blank?(Map.get(entry, key)) do
        raise ArgumentError,
              "ignore audit entry #{inspect(Map.get(entry, :module))} missing #{key}"
      end
    end)
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false

  defp as_float(value) when is_integer(value), do: value / 1
  defp as_float(value) when is_float(value), do: value
end
