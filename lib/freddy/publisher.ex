defmodule Freddy.Publisher do
  @moduledoc """
  A behaviour module for implementing Freddy-compliant AMQP publisher processes.

  The `Freddy.Publisher` module provides a way to create processes that hold,
  monitor, and restart a channel in case of failure, exports a function to publish
  messages to an exchange, and some callbacks to hook into the process lifecycle.

  An example `Freddy.Publisher` process that only sends every other message:

      defmodule MyPublisher do
        use #{__MODULE__}

        def start_link(conn, config, opts \\ []) do
          #{__MODULE__}.start_link(__MODULE__, conn, config, :ok, opts)
        end

        def publish(publisher, payload, routing_key) do
          #{__MODULE__}.publish(publisher, payload, routing_key)
        end

        def init(:ok) do
          {:ok, %{last_ignored: false}}
        end

        def before_publication(_payload, _routing_key, _opts, %{last_ignored: false}) do
          {:ignore, %{last_ignored: true}}
        end
        def before_publication(_payload, _routing_key, _opts, %{last_ignored: true}) do
          {:ok, %{last_ignored: false}}
        end
      end

  ## Channel handling

  When the `#{__MODULE__}` starts with `start_link/5` it runs the `init/1` callback
  and responds with `{:ok, pid}` on success, like a GenServer.

  After starting the process it attempts to open a channel on the given connection.
  It monitors the channel, and in case of failure it tries to reopen again and again
  on the same connection.

  ## Context setup

  The context setup process for a publisher is to declare its exchange.

  Every time a channel is open the context is set up, meaning that the exchange
  is declared through the new channel based on the given configuration.

  The configuration must be a `Keyword.t` that contains a single key: `:exchange`
  whose value is the configuration for the `Freddy.Exchange`.
  Check it for more detailed information.
  """

  use Freddy.Actor, exchange: nil

  @type routing_key :: String.t()

  @doc """
  Called before a message will be encoded and published to the exchange.

  It receives as argument the message payload, the routing key, the options
  for that publication and the internal state.

  Returning `{:ok, state}` will cause the message to be sent with no
  modification, and enter the main loop with the given state.

  Returning `{:ok, payload, routing_key, opts, state}` will cause the
  given payload, routing key and options to be used instead of the original
  ones, and enter the main loop with the given state.

  Returning `{:ignore, state}` will ignore that message and enter the main loop
  again with the given state.

  Returning `{:stop, reason, state}` will not send the message, terminate the
  main loop and call `terminate(reason, state)` before the process exits with
  reason `reason`.
  """
  @callback before_publication(payload, routing_key, opts :: Keyword.t(), state) ::
              {:ok, state}
              | {:ok, payload, routing_key, opts :: Keyword.t(), state}
              | {:ignore, state}
              | {:stop, reason :: term, state}

  @doc """
  Called before a message will be published to the exchange.

  It receives as argument the message payload, the routing key, the options
  for that publication and the internal state.

  Returning `{:ok, string, state}` will cause the returned `string` to be
  published to the exchange, and the process to enter the main loop with the
  given state.

  Returning `{:ok, string, routing_key, opts, state}` will cause the
  given string, routing key and options to be used instead of the original
  ones, and enter the main loop with the given state.

  Returning `{:ignore, state}` will ignore that message and enter the main loop
  again with the given state.

  Returning `{:stop, reason, state}` will not send the message, terminate the
  main loop and call `terminate(reason, state)` before the process exits with
  reason `reason`.
  """
  @callback encode_message(payload, routing_key, opts :: Keyword.t(), state) ::
              {:ok, String.t(), state}
              | {:ok, String.t(), routing_key, opts :: Keyword.t(), state}
              | {:ignore, state}
              | {:stop, reason :: term, state}

  defmacro __using__(_opts \\ []) do
    quote location: :keep do
      @behaviour Freddy.Publisher

      @impl true
      def init(initial) do
        {:ok, initial}
      end

      @impl true
      def handle_connected(state) do
        {:noreply, state}
      end

      @impl true
      def handle_disconnected(_reason, state) do
        {:noreply, state}
      end

      @impl true
      def before_publication(_payload, _routing_key, _opts, state) do
        {:ok, state}
      end

      @impl true
      def encode_message(payload, routing_key, opts, state) do
        case Jason.encode(payload) do
          {:ok, new_payload} ->
            opts = Keyword.put(opts, :content_type, "application/json")

            {:ok, new_payload, routing_key, opts, state}

          {:error, reason} ->
            {:stop, reason, state}
        end
      end

      @impl true
      def handle_call(message, _from, state) do
        {:stop, {:bad_call, message}, state}
      end

      @impl true
      def handle_cast(message, state) do
        {:stop, {:bad_cast, message}, state}
      end

      @impl true
      def handle_info(_message, state) do
        {:noreply, state}
      end

      @impl true
      def terminate(_reason, _state) do
        :ok
      end

      defoverridable Freddy.Publisher
    end
  end

  @doc """
  Publishes a message to an exchange through the `Freddy.Publisher` process.
  """
  @spec publish(GenServer.server(), payload :: term, routing_key :: String.t(), opts :: Keyword.t()) ::
          :ok
  def publish(publisher, payload, routing_key \\ "", opts \\ []) do
    cast(publisher, {:"$publish", payload, routing_key, opts})
  end

  alias Freddy.Exchange

  @impl true
  def handle_connected(channel, state(config: config) = state) do
    case declare_exchange(config, channel) do
      {:ok, exchange} -> super(channel, state(state, exchange: exchange))
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_cast({:"$publish", payload, routing_key, opts}, state) do
    handle_publish(payload, routing_key, opts, state)
  end

  def handle_cast(message, state) do
    super(message, state)
  end

  defp declare_exchange(config, channel) do
    exchange =
      config
      |> Keyword.get(:exchange, Exchange.default())
      |> Exchange.new()

    with :ok <- Exchange.declare(exchange, channel) do
      {:ok, exchange}
    end
  end

  defp handle_publish(payload, routing_key, opts, state(mod: mod, given: given) = state) do
    case mod.before_publication(payload, routing_key, opts, given) do
      {:ok, new_given} ->
        do_publish(payload, routing_key, opts, state(state, given: new_given))

      {:ok, new_payload, new_routing_key, new_opts, new_given} ->
        do_publish(new_payload, new_routing_key, new_opts, state(state, given: new_given))

      {:ignore, new_given} ->
        {:noreply, state(state, given: new_given)}

      {:stop, reason, new_given} ->
        {:stop, reason, state(state, given: new_given)}
    end
  end

  defp do_publish(
         payload,
         routing_key,
         opts,
         state(channel: channel, exchange: exchange, mod: mod, given: given) = state
       ) do
    case mod.encode_message(payload, routing_key, opts, given) do
      {:ok, new_payload, new_given} ->
        Exchange.publish(exchange, channel, new_payload, routing_key, opts)

        {:noreply, state(state, given: new_given)}

      {:ok, new_payload, new_routing_key, new_opts, new_given} ->
        Exchange.publish(exchange, channel, new_payload, new_routing_key, new_opts)

        {:noreply, state(state, given: new_given)}

      {:ignore, new_given} ->
        {:noreply, state(state, given: new_given)}

      {:stop, reason, new_given} ->
        {:stop, reason, state(state, given: new_given)}
    end
  end
end
