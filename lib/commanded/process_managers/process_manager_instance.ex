defmodule Commanded.ProcessManagers.ProcessManagerInstance do
  @moduledoc false

  use GenServer

  require Logger

  alias Commanded.ProcessManagers.{ProcessRouter, ProcessManagerInstance, FailureContext}
  alias Commanded.EventStore
  alias Commanded.EventStore.{RecordedEvent, SnapshotData}

  defstruct [
    :command_dispatcher,
    :process_router,
    :process_manager_name,
    :process_manager_module,
    :process_uuid,
    :process_state,
    :last_seen_event
  ]

  def start_link(
        command_dispatcher,
        process_router,
        process_manager_name,
        process_manager_module,
        process_uuid
      ) do
    state = %ProcessManagerInstance{
      command_dispatcher: command_dispatcher,
      process_router: process_router,
      process_manager_name: process_manager_name,
      process_manager_module: process_manager_module,
      process_uuid: process_uuid,
      process_state: struct(process_manager_module)
    }

    GenServer.start_link(__MODULE__, state)
  end

  def init(%ProcessManagerInstance{} = state) do
    GenServer.cast(self(), :fetch_state)

    {:ok, state}
  end

  @doc """
  Checks whether or not the process manager has already processed events
  """
  def new?(process_manager) do
    GenServer.call(process_manager, :new?)
  end

  @doc """
  Handle the given event by delegating to the process manager module
  """
  def process_event(process_manager, %RecordedEvent{} = event) do
    GenServer.cast(process_manager, {:process_event, event})
  end

  @doc """
  Stop the given process manager and delete its persisted state.

  Typically called when it has reached its final state.
  """
  def stop(process_manager) do
    GenServer.call(process_manager, :stop)
  end

  @doc """
  Fetch the process state of this instance
  """
  def process_state(process_manager) do
    GenServer.call(process_manager, :process_state)
  end

  @doc false
  def handle_call(:stop, _from, %ProcessManagerInstance{} = state) do
    :ok = delete_state(state)

    # stop the process with a normal reason
    {:stop, :normal, :ok, state}
  end

  @doc false
  def handle_call(:process_state, _from, %ProcessManagerInstance{} = state) do
    %ProcessManagerInstance{process_state: process_state} = state

    {:reply, process_state, state}
  end

  @doc false
  def handle_call(:new?, _from, %ProcessManagerInstance{} = state) do
    %ProcessManagerInstance{last_seen_event: last_seen_event} = state

    {:reply, is_nil(last_seen_event), state}
  end

  @doc """
  Attempt to fetch intial process state from snapshot storage
  """
  def handle_cast(:fetch_state, %ProcessManagerInstance{} = state) do
    state =
      case EventStore.read_snapshot(process_state_uuid(state)) do
        {:ok, snapshot} ->
          %ProcessManagerInstance{
            state
            | process_state: snapshot.data,
              last_seen_event: snapshot.source_version
          }

        {:error, :snapshot_not_found} ->
          state
      end

    {:noreply, state}
  end

  @doc """
  Handle the given event, using the process manager module, against the current process state
  """
  def handle_cast({:process_event, event}, %ProcessManagerInstance{} = state) do
    case event_already_seen?(event, state) do
      true -> process_seen_event(event, state)
      false -> process_unseen_event(event, state)
    end
  end

  defp event_already_seen?(
         %RecordedEvent{event_number: event_number},
         %ProcessManagerInstance{last_seen_event: last_seen_event}
       ) do
    not is_nil(last_seen_event) and event_number <= last_seen_event
  end

  # Already seen event, so just ack
  defp process_seen_event(event, state) do
    :ok = ack_event(event, state)

    {:noreply, state}
  end

  defp process_unseen_event(event, state, context \\ %{}) do
    %RecordedEvent{
      correlation_id: correlation_id,
      event_id: event_id,
      event_number: event_number
    } = event

    case handle_event(event, state) do
      {:error, error} ->
        Logger.error(fn ->
          describe(state) <>
            " failed to handle event #{inspect(event_number)} due to: #{inspect(error)}"
        end)

        handle_event_error({:error, error}, event, state, context)

      {:stop, _error, _state} = reply ->
        reply

      commands ->
        # Copy event id, as causation id, and correlation id from handled event.
        opts = [causation_id: event_id, correlation_id: correlation_id]

        with :ok <- commands |> List.wrap() |> dispatch_commands(opts, state, event) do
          process_state = mutate_state(event, state)

          state = %ProcessManagerInstance{
            state
            | process_state: process_state,
              last_seen_event: event_number
          }

          :ok = persist_state(event_number, state)
          :ok = ack_event(event, state)

          {:noreply, state}
        else
          {:stop, reason} ->
            {:stop, reason, state}
        end
    end
  end

  # Process instance is given the event and returns applicable commands
  # (may be none, one or many).
  defp handle_event(%RecordedEvent{} = event, %ProcessManagerInstance{} = state) do
    %RecordedEvent{data: data} = event

    %ProcessManagerInstance{
      process_manager_module: process_manager_module,
      process_state: process_state
    } = state

    try do
      process_manager_module.handle(process_state, data)
    rescue
      e ->
        {:error, e}
    end
  end

  defp handle_event_error(error, failed_event, state, context) do
    %RecordedEvent{data: data} = failed_event
    %ProcessManagerInstance{process_manager_module: process_manager_module} = state

    failure_context = %FailureContext{
      pending_commands: [],
      process_manager_state: state,
      last_event: failed_event,
      context: context
    }

    case process_manager_module.error(error, data, failure_context) do
      {:retry, context} when is_map(context) ->
        # Retry the failed event
        Logger.info(fn -> describe(state) <> " is retrying failed event" end)

        process_unseen_event(failed_event, state, context)

      {:retry, delay, context} when is_map(context) and is_integer(delay) and delay >= 0 ->
        # Retry the failed event after waiting for the given delay, in milliseconds
        Logger.info(fn ->
          describe(state) <> " is retrying failed event after #{inspect(delay)}ms"
        end)

        :timer.sleep(delay)

        process_unseen_event(failed_event, state, context)

      :skip ->
        # Skip the failed event by confirming receipt
        Logger.info(fn -> describe(state) <> " is skipping event" end)

        :ok = ack_event(failed_event, state)

        {:noreply, state}

      {:stop, error} ->
        # Stop the process manager instance
        Logger.warn(fn -> describe(state) <> " has requested to stop: #{inspect(error)}" end)

        {:stop, error, state}

      invalid ->
        Logger.warn(fn ->
          describe(state) <> " returned an invalid error reponse: #{inspect(invalid)}"
        end)

        # Stop process manager with original error
        {:stop, error, state}
    end
  end

  # update the process instance's state by applying the event
  defp mutate_state(%RecordedEvent{data: data}, %ProcessManagerInstance{
         process_manager_module: process_manager_module,
         process_state: process_state
       }) do
    process_manager_module.apply(process_state, data)
  end

  defp dispatch_commands(commands, opts, state, last_event, context \\ %{})
  defp dispatch_commands([], _opts, _state, _last_event, _context), do: :ok

  defp dispatch_commands([command | pending_commands], opts, state, last_event, context) do
    Logger.debug(fn ->
      describe(state) <> " attempting to dispatch command: #{inspect(command)}"
    end)

    case state.command_dispatcher.dispatch(command, opts) do
      :ok ->
        dispatch_commands(pending_commands, opts, state, last_event)

      error ->
        Logger.warn(fn ->
          describe(state) <>
            " failed to dispatch command #{inspect(command)} due to: #{inspect(error)}"
        end)

        failure_context = %FailureContext{
          pending_commands: pending_commands,
          process_manager_state: mutate_state(last_event, state),
          last_event: last_event,
          context: context
        }

        dispatch_failure(error, command, opts, state, failure_context)
    end
  end

  defp dispatch_failure(error, failed_command, opts, state, failure_context) do
    %ProcessManagerInstance{process_manager_module: process_manager_module} = state
    %FailureContext{pending_commands: pending_commands, last_event: last_event} = failure_context

    case process_manager_module.error(error, failed_command, failure_context) do
      {:continue, commands, context} when is_list(commands) ->
        # continue dispatching the given commands
        Logger.info(fn -> describe(state) <> " is continuing with modified command(s)" end)

        dispatch_commands(commands, opts, state, last_event, context)

      {:retry, context} ->
        # retry the failed command immediately
        Logger.info(fn -> describe(state) <> " is retrying failed command" end)

        dispatch_commands([failed_command | pending_commands], opts, state, last_event, context)

      {:retry, delay, context} when is_integer(delay) ->
        # retry the failed command after waiting for the given delay, in milliseconds
        Logger.info(fn ->
          describe(state) <> " is retrying failed command after #{inspect(delay)}ms"
        end)

        :timer.sleep(delay)

        dispatch_commands([failed_command | pending_commands], opts, state, last_event, context)

      {:skip, :discard_pending} ->
        # skip the failed command and discard any pending commands
        Logger.info(fn ->
          describe(state) <>
            " is skipping event and #{length(pending_commands)} pending command(s)"
        end)

        :ok

      {:skip, :continue_pending} ->
        # skip the failed command, but continue dispatching any pending commands
        Logger.info(fn -> describe(state) <> " is ignoring error dispatching command" end)

        dispatch_commands(pending_commands, opts, state, last_event)

      {:stop, reason} = reply ->
        # stop process manager
        Logger.warn(fn -> describe(state) <> " has requested to stop: #{inspect(reason)}" end)

        reply
    end
  end

  defp describe(%ProcessManagerInstance{process_manager_module: process_manager_module}),
    do: inspect(process_manager_module)

  defp persist_state(source_version, %ProcessManagerInstance{} = state) do
    %ProcessManagerInstance{
      process_manager_module: process_manager_module,
      process_state: process_state
    } = state

    EventStore.record_snapshot(%SnapshotData{
      source_uuid: process_state_uuid(state),
      source_version: source_version,
      source_type: Atom.to_string(process_manager_module),
      data: process_state
    })
  end

  defp delete_state(%ProcessManagerInstance{} = state) do
    EventStore.delete_snapshot(process_state_uuid(state))
  end

  defp ack_event(%RecordedEvent{} = event, %ProcessManagerInstance{} = state) do
    %ProcessManagerInstance{process_router: process_router} = state

    ProcessRouter.ack_event(process_router, event, self())
  end

  defp process_state_uuid(%ProcessManagerInstance{} = state) do
    %ProcessManagerInstance{
      process_manager_name: process_manager_name,
      process_uuid: process_uuid
    } = state

    "#{process_manager_name}-#{process_uuid}"
  end
end
