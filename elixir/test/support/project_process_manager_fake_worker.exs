args =
  case OptionParser.parse(System.argv(),
         strict: [mode: :string, port: :integer],
         aliases: [m: :mode, p: :port]
       ) do
    {opts, _, []} -> opts
    _other -> []
  end

mode = Keyword.get(args, :mode, "normal")
port = Keyword.get(args, :port, 0)

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
        _ = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nok"
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
        _ = :gen_tcp.recv(socket, 0, :infinity)
        :gen_tcp.close(socket)
      end)

      accept_loop.(accept_loop)
    end

    accept_loop.(accept_loop)

  _other ->
    IO.puts(:stderr, "unsupported fake worker mode")
    System.halt(2)
end
