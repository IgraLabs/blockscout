# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Block.WallClockStatus do
  @moduledoc """
  Terminal states for a block's recovered wall-clock time.

  Stored as `smallint` with a database `CHECK`, deliberately not a PostgreSQL
  enum: a rolling upgrade can start writing a new status without an `ALTER TYPE`
  that older nodes in the cluster cannot read.

  The numeric values are persisted and **must never be reassigned**. Adding a
  status means taking the next free integer and widening the `CHECK`.

  ## States

    * `:pending` (0) — row exists, not yet decoded or backfilled.
    * `:ok` (1) — decoded successfully; `wall_clock_timestamp`,
      `parent_beacon_block_root` and `wall_clock_decoder_version` are all set.
    * `:no_root` (2) — no `parentBeaconBlockRoot`, or a known genesis height
      whose all-zero root is legitimate. Terminal and *not* an error.
    * `:decode_failed` (3) — a root was present but did not decode under the
      decoder version active at that height. Terminal for that version; a later,
      higher version may legitimately re-attempt it.
    * `:orphan_unavailable` (4) — non-canonical block whose root could not be
      retrieved. Measured 0/200 recoverable for aged orphans, and node retention
      is a stepwise boundary rather than a duration, so this is expected to be
      permanent for historical rows. See `docs/igra-timestamp-phase0-preflight.md`.

  Only `:ok` carries a timestamp. `:pending` and the three terminal failure
  states all leave `wall_clock_timestamp` NULL, which is what lets readers use a
  single `COALESCE` fallback without inspecting the status.
  """

  @statuses %{
    pending: 0,
    ok: 1,
    no_root: 2,
    decode_failed: 3,
    orphan_unavailable: 4
  }

  @by_value Map.new(@statuses, fn {name, value} -> {value, name} end)

  @type t :: :pending | :ok | :no_root | :decode_failed | :orphan_unavailable

  @doc "All status names."
  @spec all :: [t()]
  def all, do: Map.keys(@statuses)

  @doc """
  Numeric value stored in `blocks.wall_clock_decode_status`.

      iex> Explorer.Chain.Block.WallClockStatus.value(:ok)
      1
  """
  @spec value(t()) :: non_neg_integer()
  for {name, value} <- @statuses do
    def value(unquote(name)), do: unquote(value)
  end

  @doc """
  Status name for a stored value, or `nil` if unknown.

  Returns `nil` rather than raising so that a node reading rows written by a
  newer release -- which may use a status this build does not know -- degrades
  to "unrecognised" instead of crashing a query.

      iex> Explorer.Chain.Block.WallClockStatus.name(1)
      :ok
      iex> Explorer.Chain.Block.WallClockStatus.name(99)
      nil
  """
  @spec name(integer() | nil) :: t() | nil
  def name(nil), do: nil

  for {value, atom} <- @by_value do
    def name(unquote(value)), do: unquote(atom)
  end

  def name(_other), do: nil

  @doc """
  Whether a status is terminal for the decoder version that produced it.

  `:pending` is the only non-terminal state. `:decode_failed` is terminal for
  its own version but may be revisited by a higher one.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(:pending), do: false
  def terminal?(status) when is_map_key(@statuses, status), do: true

  @doc "Statuses that must leave `wall_clock_timestamp` NULL."
  @spec without_timestamp :: [t()]
  def without_timestamp, do: [:pending, :no_root, :decode_failed, :orphan_unavailable]
end
