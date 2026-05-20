import Config

config :symphony_elixir, :coverage_policy,
  tiers: %{
    SymphonyElixir.RunTrace => %{tier: :a, current_baseline: 96.85},
    SymphonyElixir.StateReducer => %{tier: :a, current_baseline: 97.94},
    SymphonyElixir.M3Precheck => %{tier: :a, current_baseline: 97.79},
    SymphonyElixir.ProjectProcessManager => %{tier: :a, current_baseline: 99.06},
    SymphonyElixir.WorkflowStore => %{tier: :a, current_baseline: 97.83},
    SymphonyElixir.RunStateStore => %{tier: :a, current_baseline: 99.24},
    SymphonyElixir.EventNormalizer => %{tier: :a, current_baseline: 98.41},
    SymphonyElixir.ProjectConfigStore => %{tier: :a, current_baseline: 99.22},
    SymphonyElixir.ProjectRegistryLoader => %{tier: :a, current_baseline: 90.91},
    SymphonyElixir.WorkerHealthPoller => %{tier: :a, current_baseline: 96.88},
    SymphonyElixir.Linear.IssueDiff => %{tier: :a, current_baseline: 98.80}
  },
  thresholds: %{
    a: 99.0,
    b: 97.0,
    c: 95.0
  },
  diff_coverage: %{
    minimum: 90.0,
    tier_a_minimum: 95.0,
    mode: :enforce
  },
  ignore_audit: [
    %{
      module: SymphonyElixir.Config,
      reason: "configuration entrypoint",
      test_target: "SymphonyElixir.Config.Schema",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.Linear.Client,
      reason: "external API boundary",
      test_target: "SymphonyElixir.Linear.Adapter",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.SpecsCheck,
      reason: "mix helper compatibility shim",
      test_target: "Mix.Tasks.Specs.Check",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.Orchestrator,
      reason: "high-fanout orchestration shell pending deeper decomposition",
      test_target: "SymphonyElixir.ProjectProcessManager",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.Orchestrator.State,
      reason: "orchestrator shell state container",
      test_target: "SymphonyElixir.ProjectProcessManager",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.AgentRunner,
      reason: "runtime shell with external codex boundary",
      test_target: "SymphonyElixir.ProjectProcessManager",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.CLI,
      reason: "escript entrypoint shell",
      test_target: "SymphonyElixir.ControlCLI",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.Codex.AppServer,
      reason: "strong external process boundary",
      test_target: "SymphonyElixir.ProjectProcessManager",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.Codex.DynamicTool,
      reason: "dynamic tool bridge thin adapter",
      test_target: "SymphonyElixir.ProjectProcessManager",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.HttpServer,
      reason: "server entrypoint shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.StatusDashboard,
      reason: "terminal presenter shell",
      test_target: "SymphonyElixir.ProjectProcessManager",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.LogFile,
      reason: "filesystem adapter shell",
      test_target: "SymphonyElixir.RunTrace",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixir.Workspace,
      reason: "workspace filesystem shell",
      test_target: "SymphonyElixir.ProjectRegistryLoader",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.DashboardLive,
      reason: "liveview ui shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.Endpoint,
      reason: "phoenix endpoint shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.ErrorHTML,
      reason: "phoenix error view shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.ErrorJSON,
      reason: "phoenix error view shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.Layouts,
      reason: "phoenix layout shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.ObservabilityApiController,
      reason: "controller shell",
      test_target: "SymphonyElixirWeb.RunLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.Presenter,
      reason: "presentation adapter shell",
      test_target: "SymphonyElixirWeb.RunLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.StaticAssetController,
      reason: "static asset controller shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.StaticAssets,
      reason: "static asset helper shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.Router,
      reason: "phoenix router shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    },
    %{
      module: SymphonyElixirWeb.Router.Helpers,
      reason: "generated router helper shell",
      test_target: "SymphonyElixirWeb.ProjectLive",
      review_after: "2026-06-01"
    }
  ]
