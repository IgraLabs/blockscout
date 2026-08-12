defmodule EthereumJSONRPC.Igra.WallClock.BlockParams do
  @moduledoc """
  Merges recovered wall-clock fields into block import params.

  **Disabled by default.** With the flag off, `merge/2` returns its input
  unchanged — byte-for-byte the params Blockscout built before this module
  existed — so the import path is unaffected until someone turns it on
  deliberately.

  ## Enabling

      config :ethereum_jsonrpc, EthereumJSONRPC.Igra.WallClock,
        dual_write_enabled: true

  Read on every block rather than cached, so flipping it at runtime takes
  effect immediately:

      iex> Application.put_env(:ethereum_jsonrpc, EthereumJSONRPC.Igra.WallClock,
      ...>   Keyword.put(Application.get_env(:ethereum_jsonrpc, EthereumJSONRPC.Igra.WallClock, []),
      ...>     :dual_write_enabled, false))

  That is the kill switch. It stops new writes; it does not undo rows already
  written, which is what the migration's `down` and the `NOT VALID` constraints
  are for.

  ## Status mapping

  The decoder's outcome maps onto `Explorer.Chain.Block.WallClockStatus`:

  | decoder | status | note |
  |---|---|---|
  | `:ok` | `ok` (1) | timestamp, root and decoder version all set |
  | `:genesis` | `no_root` (2) | legitimate all-zero root at a genesis height |
  | `:decode_failed`, `error: :missing_root` | `no_root` (2) | field absent entirely |
  | `:decode_failed`, any other error | `decode_failed` (3) | root present but did not decode |

  `orphan_unavailable` (4) is never produced here — it belongs to the backfill,
  which is the only thing that fetches by hash and can observe a block's absence.

  Only `ok` carries a timestamp, which is what the database CHECK enforces.

  ## Telemetry

  Emits `[:ethereum_jsonrpc, :igra, :wall_clock, :decode]` per block with
  `%{count: 1}` and metadata `%{status: atom, decoder_version: integer | nil,
  error: atom | nil}`.

  Deliberately no block number or hash in the metadata: those are unbounded
  label values and would blow up any metrics backend that aggregates on them.
  """

  alias EthereumJSONRPC.Igra.WallClock

  # Mirrors Explorer.Chain.Block.WallClockStatus. Duplicated rather than
  # depended upon because ethereum_jsonrpc must not depend on explorer -- the
  # dependency runs the other way. The status test in explorer pins these values
  # as literals, so a divergence fails there.
  @status_ok 1
  @status_no_root 2
  @status_decode_failed 3

  @telemetry_event [:ethereum_jsonrpc, :igra, :wall_clock, :decode]

  @doc """
  Adds wall-clock fields to `params`, or returns it untouched when disabled.

  `elixir` is the block as parsed by `EthereumJSONRPC.Block`, from which the
  block number and raw `parentBeaconBlockRoot` are read.
  """
  @spec merge(map(), map()) :: map()
  def merge(params, elixir) do
    if enabled?() do
      do_merge(params, elixir)
    else
      params
    end
  end

  @doc """
  The block's recovered wall-clock time, or `nil`.

  Used to stamp the block's transactions with the same value. Returns `nil`
  whenever dual-write is disabled or the block does not decode, so callers need
  no flag check of their own.
  """
  @spec timestamp_for(map()) :: DateTime.t() | nil
  def timestamp_for(elixir) do
    if enabled?() do
      case decode(height(elixir), Map.get(elixir, "parentBeaconBlockRoot")) do
        %WallClock.Result{status: :ok, wall_clock_timestamp: timestamp} -> timestamp
        _other -> nil
      end
    end
  end

  # This is called from two places at different stages of parsing: from
  # elixir_to_params/1, where "number" is already an integer, and from the
  # transactions branch of entry_to_elixir/2, where the block is still raw
  # JSON-RPC and "number" is a quantity such as "0x0". Normalising here rather
  # than assuming one shape -- an unhandled shape used to raise a
  # FunctionClauseError from inside block parsing, which would abort the import
  # of an entire block.
  defp height(elixir) do
    case Map.get(elixir, "number") do
      number when is_integer(number) -> number
      "0x" <> _ = quantity -> safe_quantity_to_integer(quantity)
      _other -> nil
    end
  end

  defp safe_quantity_to_integer(quantity) do
    EthereumJSONRPC.quantity_to_integer(quantity)
  rescue
    _error -> nil
  end

  @doc "Whether dual-write is currently enabled."
  @spec enabled? :: boolean()
  def enabled? do
    :ethereum_jsonrpc
    |> Application.get_env(WallClock, [])
    |> Keyword.get(:dual_write_enabled, false)
  end

  defp do_merge(params, elixir) do
    number = height(elixir)
    root = Map.get(elixir, "parentBeaconBlockRoot")

    result = decode(number, root)
    emit_telemetry(result)

    Map.merge(params, fields(result, root))
  end

  # A block with no number cannot have its decoder version selected by height,
  # and height-based selection is the whole point of the versioning scheme -- so
  # this is a failure rather than a guess at version 1.
  defp decode(number, root) when is_integer(number) and number >= 0, do: WallClock.decode(number, root)

  # Covers nil and anything unparseable. Never raises: a block whose height we
  # cannot determine must be recorded as a decode failure, not crash the import.
  defp decode(_number, _root), do: %WallClock.Result{status: :decode_failed, error: :missing_block_number}

  defp fields(%WallClock.Result{status: :ok} = result, root) do
    %{
      wall_clock_timestamp: result.wall_clock_timestamp,
      parent_beacon_block_root: raw_root(root),
      wall_clock_decode_status: @status_ok,
      wall_clock_decoder_version: result.decoder_version
    }
  end

  defp fields(%WallClock.Result{status: :genesis} = result, root) do
    %{
      wall_clock_timestamp: nil,
      parent_beacon_block_root: raw_root(root),
      wall_clock_decode_status: @status_no_root,
      wall_clock_decoder_version: result.decoder_version
    }
  end

  defp fields(%WallClock.Result{status: :decode_failed, error: :missing_root} = result, _root) do
    %{
      wall_clock_timestamp: nil,
      parent_beacon_block_root: nil,
      wall_clock_decode_status: @status_no_root,
      wall_clock_decoder_version: result.decoder_version
    }
  end

  defp fields(%WallClock.Result{status: :decode_failed} = result, root) do
    %{
      wall_clock_timestamp: nil,
      # Retained even though the decode failed: it is the evidence needed to
      # diagnose why, and a later decoder version may succeed on it without
      # re-fetching the block.
      parent_beacon_block_root: raw_root(root),
      wall_clock_decode_status: @status_decode_failed,
      wall_clock_decoder_version: result.decoder_version
    }
  end

  # Stored as bytea. A value that will not parse is stored as NULL rather than raising:
  # the status already records that the decode failed, and a malformed root must
  # not abort the import of an otherwise valid block.
  defp raw_root(nil), do: nil

  defp raw_root("0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 32 -> bytes
      _ -> nil
    end
  end

  defp raw_root(root) when is_binary(root) and byte_size(root) == 32, do: root
  defp raw_root(_root), do: nil

  defp emit_telemetry(%WallClock.Result{} = result) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{status: result.status, decoder_version: result.decoder_version, error: result.error}
    )
  catch
    # Telemetry must never be able to fail an import.
    _kind, _reason -> :ok
  end
end
