defmodule Ravix.Connection.RequestExecutor do
  @moduledoc false
  use GenServer
  use Retry

  require OK
  require Logger

  @default_headers [{"content-type", "application/json"}, {"accept", "application/json"}]

  alias Ravix.Connection
  alias Ravix.Connection.State, as: ConnectionState
  alias Ravix.Connection.{ServerNode, NodeSelector, Response}
  alias Ravix.Connection.RequestExecutor
  alias Ravix.Documents.Protocols.CreateRequest

  @doc """
  Initializes the connection for the informed ServerNode

  The process will take care of the connection state, if the connection closes, the process
  will die automatically
  """
  @spec init(ServerNode.t()) ::
          {:ok, ServerNode.t()}
          | {:stop,
             %{
               :__exception__ => any,
               :__struct__ => Mint.HTTPError | Mint.TransportError,
               :reason => any,
               optional(:module) => any
             }}
  def init(%ServerNode{} = node) do
    {:ok, conn_params} = build_params(node.ssl_config, node.protocol)

    Logger.info(
      "[RAVIX] Connecting to node '#{inspect(node)}' for store '#{inspect(node.store)}'"
    )

    case Mint.HTTP.connect(node.protocol, node.url, node.port, conn_params) do
      {:ok, conn} ->
        Logger.info(
          "[RAVIX] Connected to node '#{inspect(node)}' for store '#{inspect(node.store)}'"
        )

        {:ok, %ServerNode{node | conn: conn}}

      {:error, reason} ->
        Logger.error(
          "[RAVIX] Unable to register the node '#{inspect(node)} for store '#{inspect(node.store)}', cause: #{inspect(reason)}'"
        )

        {:stop, reason}
    end
  end

  @spec start_link(any, ServerNode.t()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(_attrs, %ServerNode{} = node) do
    GenServer.start_link(
      __MODULE__,
      node,
      name: executor_id(node.url, node.database)
    )
  end

  @doc """
  Executes a RavenDB command for the informed connection

  ## Parameters

  - command: The command that will be executed, must be a RavenCommand
  - conn_state: The connection state for which this execution will be linked
  - headers: HTTP headers to send to RavenDB
  - opts: Request options

  ## Returns
  - `{:ok, Ravix.Connection.Response}` for a successful call
  - `{:error, cause}` if the request fails
  """
  @spec execute(map, ConnectionState.t(), any, keyword) :: {:error, any} | {:ok, Response.t()}
  def execute(
        command,
        %ConnectionState{} = conn_state,
        headers \\ {},
        opts \\ []
      ) do
    node_pid = NodeSelector.current_node(conn_state)
    opts = opts ++ RequestExecutor.Options.from_connection_state(conn_state)

    headers =
      case conn_state.disable_topology_updates do
        true -> headers
        false -> [{"Topology-Etag", conn_state.topology_etag}]
      end

    execute_for_node(command, node_pid, nil, headers, opts)
  end

  @doc """
  Executes a RavenDB command on the informed node

  ## Parameters

  - command: The command that will be executed, must be a RavenCommand
  - pid_or_url: The PID or the Url of the node where the command will be executed
  - database: The database name
  - headers: HTTP headers to send to RavenDB
  - opts: Request options

  ## Returns
  - `{:ok, Ravix.Connection.Response}` for a successful call
  - `{:error, cause}` if the request fails
  """
  @spec execute_for_node(map(), binary | pid, String.t() | nil, any, keyword) ::
          {:error, any} | {:ok, Response.t()}
  def execute_for_node(command, pid_or_url, database, headers \\ {}, opts \\ [])

  def execute_for_node(command, pid_or_url, _database, headers, opts) when is_pid(pid_or_url) do
    call_raven(pid_or_url, command, headers, opts)
  end

  def execute_for_node(command, pid_or_url, database, headers, opts)
      when is_bitstring(pid_or_url) do
    call_raven(executor_id(database, pid_or_url), command, headers, opts)
  end

  defp call_raven(executor, command, headers, opts) do
    should_retry = Keyword.get(opts, :retry_on_failure, false)
    retry_backoff = Keyword.get(opts, :retry_backoff, 100)

    retry_count =
      case should_retry do
        true -> Keyword.get(opts, :retry_count, 3)
        false -> 0
      end

    retry with: constant_backoff(retry_backoff) |> Stream.take(retry_count) do
      GenServer.call(executor, {:request, command, headers, opts})
    after
      {:ok, result} -> {:ok, result}
      {:non_retryable_error, response} -> {:error, response}
      {:error, error_response} -> {:error, error_response}
    else
      err -> err
    end
  end

  @doc """
  Asynchronously updates the cluster tag for the current node

  ## Parameters
  - url: Node url
  - database:  Database name
  - cluster_tag: new cluster tag

  ## Returns
  - :ok
  """
  @spec update_cluster_tag(String.t(), String.t(), String.t()) :: :ok
  def update_cluster_tag(url, database, cluster_tag) do
    GenServer.cast(executor_id(url, database), {:update_cluster_tag, cluster_tag})
  end

  @doc """
  Fetches the current node executor state

  ## Parameters
  pid = The PID of the node

  ## Returns
  - `{:ok, Ravix.Connection.ServerNode}` if there's a node
  - `{:error, :node_not_found}` if there's not a node with the informed pid
  """
  @spec fetch_node_state(bitstring | pid) :: {:ok, ServerNode.t()} | {:error, :node_not_found}
  def fetch_node_state(pid) when is_pid(pid) do
    try do
      {:ok, pid |> :sys.get_state()}
    catch
      :exit, _ -> {:error, :node_not_found}
    end
  end

  @doc """
  Fetches the current node executor state

  ## Parameters
  url = The node url
  database = the node database name

  ## Returns
  - `{:ok, Ravix.Connection.ServerNode}` if there's a node
  - `{:error, :node_not_found}` if there's not a node with the informed pid
  """
  @spec fetch_node_state(binary, binary) :: {:ok, ServerNode.t()} | {:error, :node_not_found}
  def fetch_node_state(url, database) when is_bitstring(url) do
    try do
      {:ok, executor_id(url, database) |> :sys.get_state()}
    catch
      :exit, _ -> {:error, :node_not_found}
    end
  end

  defp executor_id(url, database),
    do: {:via, Registry, {:request_executors, url <> "/" <> database}}

  ####################
  #     Handlers     #
  ####################
  def handle_call({:request, command, headers, opts}, from, %ServerNode{} = node) do
    request = CreateRequest.create_request(command, node)

    case maximum_url_length_reached?(opts, request.url) do
      true -> {:reply, {:error, :maximum_url_length_reached}, node}
      false -> exec_request(node, from, request, command, headers, opts)
    end
  end

  def handle_info(message, %ServerNode{} = node) do
    case Mint.HTTP.stream(node.conn, message) do
      :unknown ->
        _ = Logger.error(fn -> "Received unknown message: " <> inspect(message) end)
        {:noreply, node}

      {:ok, conn, responses} ->
        node = put_in(node.conn, conn)
        state = Enum.reduce(responses, node, &process_response/2)
        {:noreply, state}

      {:error, conn, error, _headers} when is_struct(error, Mint.HTTPError) ->
        node = put_in(node.conn, conn)

        _ =
          Logger.error(fn ->
            "Received error message: " <> inspect(message) <> " " <> inspect(error)
          end)

        {:noreply, node}

      {:error, _conn, error, _headers} when is_struct(error, Mint.TransportError) ->
        Logger.debug(
          "The connection with the node #{inspect(node.url)} for the store #{inspect(node.store)} timed out gracefully"
        )

        {:stop, :normal, node}
    end
  end

  def handle_cast({:update_cluster_tag, cluster_tag}, %ServerNode{} = node) do
    {:noreply, %ServerNode{node | cluster_tag: cluster_tag}}
  end

  defp exec_request(%ServerNode{} = node, from, request, command, headers, opts) do
    case Mint.HTTP.request(
           node.conn,
           request.method,
           request.url,
           @default_headers ++ [headers],
           request.data
         ) do
      {:ok, conn, request_ref} ->
        Logger.debug(
          "[RAVIX] Executing command #{inspect(command)} under the request '#{inspect(request_ref)}' for the store #{inspect(node.store)}"
        )

        node = put_in(node.conn, conn)
        node = put_in(node.requests[request_ref], %{from: from, response: %{}})
        node = put_in(node.opts, opts)
        {:noreply, node}

      {:error, conn, reason} ->
        state = put_in(node.conn, conn)
        {:reply, {:error, reason}, state}
    end
  end

  defp process_response({:status, request_ref, status}, state) do
    put_in(state.requests[request_ref].response[:status], status)
  end

  defp process_response({:headers, request_ref, headers}, state) do
    put_in(state.requests[request_ref].response[:headers], headers)
  end

  defp process_response({:data, request_ref, new_data}, state) do
    update_in(state.requests[request_ref].response[:data], fn data -> (data || "") <> new_data end)
  end

  defp process_response({:done, request_ref}, state) do
    {%{response: response, from: from}, state} = pop_in(state.requests[request_ref])
    response = put_in(response[:data], decode_body(response[:data]))

    parsed_response =
      case response do
        %{status: 404} ->
          {:non_retryable_error, :document_not_found}

        %{status: 403} ->
          {:non_retryable_error, :unauthorized}

        %{status: 409} ->
          {:error, :conflict}

        %{status: 410} ->
          {:error, :node_gone}

        %{data: :invalid_response_payload} ->
          {:non_retryable_error, "Unable to parse the response payload"}

        %{data: data} when is_map_key(data, "Error") ->
          {:non_retryable_error, data["Message"]}

        %{data: %{"IsStale" => true}} ->
          Logger.warn("[RAVIX] The request '#{inspect(request_ref)}' is Stale!")

          case ServerNode.retry_on_stale?(state) do
            true -> {:error, :stale}
            false -> {:non_retryable_error, :stale}
          end

        error_response when error_response.status in [408, 502, 503, 504] ->
          parse_error(error_response)

        parsed_response ->
          {:ok, parsed_response}
      end
      |> check_if_needs_topology_update(state)

    Logger.debug(
      "[RAVIX] Request #{inspect(request_ref)} finished with response #{inspect(parsed_response)}"
    )

    GenServer.reply(from, parsed_response)

    state
  end

  defp check_if_needs_topology_update({:ok, response}, %ServerNode{} = node) do
    case Enum.find(response.headers, fn header -> elem(header, 0) == "Refresh-Topology" end) do
      nil ->
        {:ok, response}

      _ ->
        Logger.debug(
          "[RAVIX] The database requested a topology refresh for the store '#{inspect(node.store)}'"
        )

        Connection.update_topology(node.store)
        {:ok, response}
    end
  end

  defp check_if_needs_topology_update({error_kind, err}, _), do: {error_kind, err}

  defp parse_error(error_response) do
    case Enum.find(error_response.headers, fn header -> elem(header, 0) == "Database-Missing" end) do
      nil ->
        {:retryable_error, error_response.data["Message"]}

      _ ->
        {:error, error_response.data["Message"]}
    end
  end

  defp build_params(_, :http), do: {:ok, []}

  defp build_params(ssl_config, :https) do
    case ssl_config do
      [] ->
        {:error, :no_ssl_configurations_informed}

      transport_ops ->
        {:ok, transport_opts: transport_ops}
    end
  end

  defp decode_body(raw_response) when is_binary(raw_response) do
    case Jason.decode(raw_response) do
      {:ok, parsed_response} -> parsed_response
      {:error, %Jason.DecodeError{}} -> :invalid_response_payload
    end
  end

  defp decode_body(_), do: nil

  @spec maximum_url_length_reached?(keyword(), String.t()) :: boolean()
  defp maximum_url_length_reached?(opts, url) do
    max_url_length = Keyword.get(opts, :max_length_of_query_using_get_url, 1024 + 512)

    String.length(url) > max_url_length
  end
end
