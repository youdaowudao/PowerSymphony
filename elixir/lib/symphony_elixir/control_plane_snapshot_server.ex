defmodule SymphonyElixir.ControlPlaneSnapshotServer do
  @moduledoc """
  Static snapshot server used by the standalone control plane.
  """

  use GenServer

  @empty_snapshot %{
    running: [],
    retrying: [],
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil
  }

  @default_refresh_payload %{
    queued: false,
    coalesced: false,
    requested_at: nil,
    operations: []
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       snapshot: Keyword.get(opts, :snapshot, @empty_snapshot),
       refresh: Keyword.get(opts, :refresh, @default_refresh_payload)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_call(:request_refresh, _from, state) do
    {:reply, Map.put(state.refresh, :requested_at, DateTime.utc_now()), state}
  end
end
