args =
  case OptionParser.parse(System.argv(),
         strict: [mode: :string, port: :integer, request_log: :string],
         aliases: [m: :mode, p: :port]
       ) do
    {opts, _, []} -> opts
    _other -> []
  end

mode = Keyword.get(args, :mode, "normal")
port = Keyword.get(args, :port, 0)
request_log = Keyword.get(args, :request_log)

log_request = fn request_path ->
  if is_binary(request_log) do
    File.write!(request_log, request_path <> "\n", [:append])
  end
end

request_path = fn request ->
  case String.split(request, "\r\n", parts: 2) do
    [request_line | _rest] ->
      case String.split(request_line, " ", parts: 3) do
        [_method, path | _rest] -> path
        _other -> "/"
      end

    _other ->
      "/"
  end
end

case mode do
  "crash" ->
    IO.puts(:stderr, "fake worker crash")
    System.halt(1)

  "normal" ->
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    accept_loop = fn accept_loop ->
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        request =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, request} -> request
            _other -> ""
          end

        request |> request_path.() |> log_request.()

        :ok =
          :gen_tcp.send(
            socket,
            case request_path.(request) do
              "/api/v1/m3_precheck" ->
                body =
                  ~s({"generated_at":"2026-05-12T00:00:00Z","m3_enabled":true,"eligible":[{"issue_identifier":"MT-CP-1","issue_id":"cp-1","state":"Todo"}],"dispatch":[],"blocked":{"MT-CP-2":["waiting on non-terminal blockers: MT-CP-9"]},"eligible_todos":[{"issue_identifier":"MT-CP-1","issue_id":"cp-1","state":"Todo"}],"dispatched_todos":[],"capacity_queued_todos":[{"issue_identifier":"MT-CP-1","issue_id":"cp-1","state":"Todo"}],"blocked_todos":{"MT-CP-2":["waiting on non-terminal blockers: MT-CP-9"]},"current_work":{"count":1,"entries":[{"issue_id":"cp-running","issue_identifier":"RUN-CP-1","state":"In Progress","worker_host":"worker-alpha"}]},"anomalies":[{"type":"blocked_but_in_progress","issue_identifier":"MT-CP-3","issue_id":"cp-3","state":"In Progress","blocking_identifiers":["MT-CP-10"]}],"structural_errors":[],"warnings":[],"convergence_points":[],"text":"fake worker m3 precheck"})

                "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n#{body}"

              "/api/v1/state" ->
                body =
                  ~s({"generated_at":"2026-05-12T00:00:00Z","counts":{"running":1,"retrying":0},"running":[{"issue_id":"cp-run-1","issue_identifier":"MT-CP-RUN-1","title":"Fake worker summary","state":"In Progress","linear_state":"In Progress","current_phase":"codex_reasoning","current_action":"reasoning summary streaming","health":"normal","worker_host":null,"workspace_path":null,"session_id":"thread-cp-turn-7","thread_id":"thread-cp","turn_id":"turn-7","turn_count":7,"last_event":"notification","last_message":"rendered","started_at":"2026-05-12T00:00:00Z","last_event_at":"2026-05-12T00:08:00Z","run_duration_seconds":480,"last_error":null,"tokens":{"input_tokens":4,"output_tokens":8,"total_tokens":12}}],"retrying":[],"codex_totals":{"input_tokens":4,"output_tokens":8,"total_tokens":12,"seconds_running":480},"rate_limits":null})

                "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n#{body}"

              _other ->
                "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nok"
            end
          )

        :gen_tcp.close(socket)
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  "hang" ->
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    accept_loop = fn accept_loop ->
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        request =
          case :gen_tcp.recv(socket, 0, :infinity) do
            {:ok, request} -> request
            _other -> ""
          end

        request |> request_path.() |> log_request.()

        receive do
        after
          :infinity -> :ok
        end
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  "hang_once" ->
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    {:ok, first_health_pending} = Agent.start_link(fn -> true end)

    accept_loop = fn accept_loop ->
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        request =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, request} -> request
            _other -> ""
          end

        path = request_path.(request)
        log_request.(path)

        hang_this_request? =
          path == "/api/v1/health" and
            Agent.get_and_update(first_health_pending, fn
              true -> {true, false}
              false -> {false, false}
            end)

        if hang_this_request? do
          receive do
          after
            :infinity -> :ok
          end
        else
          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nok"
            )

          :gen_tcp.close(socket)
        end
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  "ok_then_hang" ->
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    {:ok, first_health_pending} = Agent.start_link(fn -> true end)

    accept_loop = fn accept_loop ->
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        request =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, request} -> request
            _other -> ""
          end

        path = request_path.(request)
        log_request.(path)

        send_response? =
          path != "/api/v1/health" or
            Agent.get_and_update(first_health_pending, fn
              true -> {true, false}
              false -> {false, false}
            end)

        if send_response? do
          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nok"
            )

          :gen_tcp.close(socket)
        else
          receive do
          after
            :infinity -> :ok
          end
        end
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  "status_503" ->
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    accept_loop = fn accept_loop ->
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        request =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, request} -> request
            _other -> ""
          end

        request |> request_path.() |> log_request.()

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 3\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nnope"
          )

        :gen_tcp.close(socket)
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  "close" ->
    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

    accept_loop = fn accept_loop ->
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        request =
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, request} -> request
            _other -> ""
          end

        request |> request_path.() |> log_request.()
        :gen_tcp.close(socket)
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  _other ->
    IO.puts(:stderr, "unsupported fake worker mode")
    System.halt(2)
end
