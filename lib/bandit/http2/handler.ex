defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler. Responsible for:

  * Coordinating the parsing of frames & attendant error handling
  * Tracking connection state as represented by `Bandit.HTTP2.Connection` structs
  * Marshalling send requests from child streams into the parent connection for processing
  """

  use ThousandIsland.Handler

  alias Bandit.HTTP2.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    case Connection.init(socket, state.plug) do
      {:ok, connection} ->
        {:ok, :continue, state |> Map.merge(%{buffer: <<>>, connection: connection})}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(&Frame.deserialize/1)
    |> Enum.reduce_while({:ok, :continue, state}, fn
      {:ok, nil}, {:ok, :continue, state} ->
        {:cont, {:ok, :continue, state}}

      {:ok, frame}, {:ok, :continue, state} ->
        case Connection.handle_frame(frame, socket, state.connection) do
          {:ok, :continue, connection} ->
            {:cont, {:ok, :continue, %{state | connection: connection}}}

          {:ok, :close, connection} ->
            {:halt, {:ok, :close, %{state | connection: connection}}}

          {:error, reason, connection} ->
            {:halt, {:error, reason, %{state | connection: connection}}}
        end

      {:more, rest}, {:ok, :continue, state} ->
        {:halt, {:ok, :continue, %{state | buffer: rest}}}

      {:error, _stream_id, code, reason}, {:ok, :continue, state} ->
        # We encountered an error while deserializing the frame. Let the connection figure out
        # how to respond to it
        case Connection.handle_error(code, reason, socket, state.connection) do
          {:ok, :close, connection} ->
            {:halt, {:ok, :close, %{state | connection: connection}}}

          {:error, reason, connection} ->
            {:halt, {:error, reason, %{state | connection: connection}}}
        end
    end)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, state) do
    Connection.connection_terminated(socket, state.connection)
  end

  def handle_call({:send_headers, stream_id, headers, end_stream}, {from, _tag}, {socket, state}) do
    case Connection.send_headers(stream_id, from, headers, end_stream, socket, state.connection) do
      {:ok, connection} ->
        {:reply, :ok, {socket, %{state | connection: connection}}}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, state}}

      {:error, reason, connection} ->
        {:stop, reason, {:error, reason}, {socket, %{state | connection: connection}}}
    end
  end

  def handle_call({:send_data, stream_id, data, end_stream}, {from, _tag}, {socket, state}) do
    case Connection.send_data(stream_id, from, data, end_stream, socket, state.connection) do
      {:ok, connection} -> {:reply, :ok, {socket, %{state | connection: connection}}}
      {:error, reason} -> {:reply, {:error, reason}, {socket, state}}
    end
  end

  def handle_info({:EXIT, pid, reason}, {socket, state}) do
    case Connection.stream_terminated(pid, reason, socket, state.connection) do
      {:ok, connection} -> {:noreply, {socket, %{state | connection: connection}}}
      {:error, _error} -> {:noreply, {socket, state}}
    end
  end
end
