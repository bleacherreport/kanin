defmodule Kanin.ConnectionManager do
  @moduledoc """
  AMQP Connection Manager.

  This module is intended to be used in the context of a supervision tree.
  It provides a process that will manage a connection to an AMQP server,
  provides mechanism for configurable exponential backoff, and connection
  retry.
  """
  use GenServer
  require Logger

  alias Kanin.Backoff
  alias Kanin.ConnectionManager.State

  @type backoff :: [{:min, pos_integer()}, {:max, pos_integer()}]

  @type connection_option ::
          {:username, String.t()}
          | {:password, String.t()}
          | {:virtual_host, String.t()}
          | {:host, String.t()}
          | {:port, pos_integer()}
          | {:channel_max, pos_integer()}
          | {:frame_max, pos_integer()}
          | {:heartbeat, pos_integer()}
          | {:connection_timeout, pos_integer()}
          | {:backoff, backoff()}
          | {:ssl_options, [:ssl.ssl_option()]}
          | {:client_properties, [...]}
          | {:socket_options, [:gen_tcp.option()]}

  @type connection_options :: [connection_option()]

  defmodule State do
    @moduledoc false

    @type connection_options :: Keyword.t()

    @type timer :: {reference() | nil, Backoff.t()}

    @type t :: %__MODULE__{
            connection_options: connection_options(),
            connection_monitor: reference() | nil,
            state: :disconnected | AMQP.Connection.t(),
            timer: timer()
          }

    defstruct connection_options: [],
              connection_monitor: nil,
              state: :disconnected,
              timer: {nil, %Backoff{}}
  end

  # Public API

  @doc """
  Starts a connection manager process linked to the current process.

  This is intended to be called from a supervision tree.

  ## Connection Options

    * `:username` - The name of a user registered with the broker (defaults to \"guest\");
    * `:password` - The password of user (defaults to \"guest\");
    * `:virtual_host` - The name of a virtual host in the broker (defaults to \"/\");
    * `:host` - The hostname of the broker (defaults to \"localhost\");
    * `:port` - The port the broker is listening on (defaults to `5672`);
    * `:channel_max` - The channel_max handshake parameter (defaults to `0`);
    * `:frame_max` - The frame_max handshake parameter (defaults to `0`);
    * `:heartbeat` - The hearbeat interval in seconds (defaults to `10`);
    * `:connection_timeout` - The connection timeout in milliseconds (defaults to `60000`);
    * `:ssl_options` - Enable SSL by setting the location to cert files (defaults to `none`);
    * `:client_properties` - A list of extra client properties to be sent to the server, defaults to `[]`;
    * `:socket_options` - Extra socket options. These are appended to the default options. \
                          See http://www.erlang.org/doc/man/inet.html#setopts-2 and http://www.erlang.org/doc/man/gen_tcp.html#connect-4 \
                          for descriptions of the available options.
  ## Enabling SSL

  To enable SSL, supply the following in the `ssl_options` field:
    * `cacertfile` - Specifies the certificates of the root Certificate Authorities that we wish to implicitly trust;
    * `certfile` - The client's own certificate in PEM format;
    * `keyfile` - The client's private key in PEM format;

  """
  @spec start_link(connection_options(), GenServer.options()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @doc """
  Opens a channel on the managed connection.

  ## Examples

      # Healthy connection

      {:ok, pid} = Kanin.ConnectionManager.start_link([...])
      {:ok, chan} = Kanin.ConnectionManager.open_channel(pid)

      # Disconnected

      {:error, :disconnected} = Kanin.ConnectionManager.open_channel(pid)

  """
  @spec open_channel(GenServer.server(), pos_integer()) ::
          {:ok, AMQP.Channel.t()} | {:error, any()}
  def open_channel(server, timeout \\ 5000) do
    GenServer.call(server, :open_channel, timeout)
  end

  # GenServer Callbacks

  @impl true
  def init(config) do
    send(self(), :connect)

    {backoff, config} = Keyword.pop(config, :backoff, [])

    {:ok,
     %State{
       connection_options: config,
       timer: {nil, Backoff.new(backoff)}
     }}
  end

  @impl true
  def handle_call(:open_channel, _from, %State{state: :disconnected} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_call(:open_channel, _from, %State{state: conn} = state) do
    {:reply, AMQP.Channel.open(conn), state}
  end

  @impl true
  def handle_info(
        :connect,
        %State{state: :disconnected, connection_options: opts, timer: timer} = state
      ) do
    case AMQP.Connection.open(opts) do
      {:ok, %AMQP.Connection{pid: pid} = conn} ->
        ref = Process.monitor(pid)

        {:noreply,
         %State{state | connection_monitor: ref, state: conn, timer: reset_timer(timer)}}

      {:error, reason} ->
        Logger.error("Unable to connect to AMQP server - reason: #{inspect(reason)}")
        {:noreply, %State{state | timer: backoff(timer)}}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %State{connection_monitor: ref, state: %AMQP.Connection{pid: pid}} = state
      ) do
    Logger.error("AMQP connection dropped; Attempting to reconnect.")

    {:noreply,
     %State{
       state
       | connection_monitor: nil,
         state: :disconnected,
         timer: reset_timer(state.timer)
     }}
  end

  @impl true
  def terminate(_reason, %State{state: :disconnected}), do: :ok

  def terminate(_reason, %State{state: %AMQP.Connection{pid: pid} = conn, connection_monitor: ref}) do
    :ok = AMQP.Connection.close(conn)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Private helpers

  defp backoff({nil, %Backoff{state: nil} = backoff}),
    do: connect_after(Backoff.next(backoff))

  defp backoff({ref, %Backoff{} = backoff}) do
    if ref, do: Process.cancel_timer(ref)
    connect_after(Backoff.next(backoff))
  end

  defp reset_timer({ref, backoff}) do
    if ref, do: Process.cancel_timer(ref)
    {nil, Backoff.reset(backoff)}
  end

  defp connect_after({nil, backoff}),
    do: connect_after({0, backoff})

  defp connect_after({ms, backoff}) do
    ref = Process.send_after(self(), :connect, ms)
    {ref, backoff}
  end
end
