defmodule EthereumJSONRPC.Igra.WallClock do
  @moduledoc """
  Recovers real wall-clock time for Igra blocks from `parentBeaconBlockRoot`.

  ## Why this exists

  Igra's `block.timestamp` is synthetic. It is derived from the Kaspa DAA score
  assuming exactly 10 DAA increments per second:

      f(daa_score) = REF_TIMESTAMP + (daa_score - REF_DAA_SCORE) / 10

  The realized Kaspa rate is slightly below 10/s, so the synthetic clock runs
  behind wall time. Rendering it faithfully makes a sub-second-finality chain
  look stalled.

  The offset is **not monotonic**. Measured over a 61-point series spanning the
  chain (2026-08-12, pinned to the finalized boundary): realized rate 9.999626/s,
  mean drift +3.23 s/day, but the offset ranges from **-187 s to +772 s**, changes
  sign 12 times, and narrows in 30 of 60 sampled intervals. Nothing here may
  assume the offset only grows, or that it is positive.

  Igra therefore carries a correction in the `parentBeaconBlockRoot` field.
  Despite the EIP-4788 name, on Igra that field does *not* hold a beacon root —
  it describes the block's **own** DAA window:

      real_timestamp = f(first_daa_score) + sign_extend(first_time_delta, 25)

  ## Bit layout

  The 32-byte root is read MSB-first as a single 256-bit big-endian integer:

      | field              | bits | signed |
      |--------------------|------|--------|
      | block_count        |    4 | no     |
      | first_daa_score    |   38 | no     |
      | first_time_delta   |   25 | yes    |
      | subsequent_deltas  | 9x21 | -      |

  4 + 38 + 25 + 189 = 256.

  ## Validation status of each field

  Nothing here is protocol-confirmed. The layout is our reading of
  `for-developers/igra-timestamp-mechanics`, whose published figures are known to
  be stale, and written confirmation is still outstanding — see
  `docs/igra-timestamp-phase0-preflight.md` §3.

  `block_count`, `first_daa_score` and `first_time_delta` are **corroborated**:
  they decode consistently across sampled blocks spanning the chain, and the
  recovered times agree with observed wall clock. An earlier claim that an
  independent verifier decoded all 13,930,499 canonical blocks with zero failures
  was **never recorded with a commit, seed, or output checksum**, so it does not
  support this module; the full-chain scan is tracked as gate P2 and has not run.

  `subsequent_deltas` are **not validated at all**. They are surfaced raw and
  unsigned for diagnostics only. Nothing in this module or downstream may depend
  on them until the protocol owners confirm their width and signedness.

  ## Versioning

  The decoder version is selected by **block height**, never inferred from the
  payload — a payload-sniffing decoder would silently mis-decode history if the
  encoding ever changes at a fork. Configure activations with:

      config :ethereum_jsonrpc, EthereumJSONRPC.Igra.WallClock,
        decoder_activations: [{0, 1}, {20_000_000, 2}],
        genesis_heights: [0]

  Each tuple is `{activation_height, version}`, and a version applies from its
  activation height up to the next one. `{0, 1}` is the default.

  Should `REF_TIMESTAMP`/`REF_DAA_SCORE` ever be re-anchored, that is a new
  decoder version with its own activation height — previously decoded history
  must not be reinterpreted under new constants.
  """

  # Must precede the module attributes below, which use `<<<`.
  import Bitwise

  require Logger

  @typedoc "Terminal per-block decode outcome."
  @type status :: :ok | :genesis | :decode_failed

  # Anchor constants for decoder v1.
  @ref_timestamp 1_771_977_542
  @ref_daa_score 365_578_320

  # DAA increments per second, assumed by the synthetic clock.
  @daa_per_second 10

  # Bit widths, MSB-first.
  @block_count_bits 4
  @first_daa_score_bits 38
  @first_time_delta_bits 25
  @subsequent_delta_bits 21
  @subsequent_delta_count 9

  @root_bytes 32

  # `first_time_delta` is a two's-complement value of @first_time_delta_bits.
  @first_time_delta_sign_bit 1 <<< (@first_time_delta_bits - 1)
  @first_time_delta_modulus 1 <<< @first_time_delta_bits

  # One delta slot for the first block plus @subsequent_delta_count more.
  @max_block_count @subsequent_delta_count + 1

  # Sanity bounds on a recovered timestamp. Deliberately wide: this rejects
  # structurally impossible values only. It is NOT a proximity check — see
  # `within_wall_clock_tolerance?/2`, which applies only to head blocks.
  # 2020-01-01T00:00:00Z and 2100-01-01T00:00:00Z.
  @min_plausible_unix 1_577_836_800
  @max_plausible_unix 4_102_444_800

  @supported_versions [1]

  defmodule Result do
    @moduledoc """
    Typed result of a `EthereumJSONRPC.Igra.WallClock` decode.

    `wall_clock_timestamp` is non-nil only when `status` is `:ok`. `:genesis`
    and `:decode_failed` are terminal for the attempted `decoder_version`; a
    later, higher version may legitimately re-attempt a `:decode_failed` row,
    but must never downgrade a row already written by a higher version.
    """

    @type t :: %__MODULE__{
            wall_clock_timestamp: DateTime.t() | nil,
            status: EthereumJSONRPC.Igra.WallClock.status(),
            decoder_version: pos_integer(),
            block_count: non_neg_integer() | nil,
            first_daa_score: non_neg_integer() | nil,
            first_time_delta: integer() | nil,
            subsequent_deltas: [non_neg_integer()] | nil,
            error: atom() | nil
          }

    defstruct [
      :wall_clock_timestamp,
      :status,
      :decoder_version,
      :block_count,
      :first_daa_score,
      :first_time_delta,
      :subsequent_deltas,
      :error
    ]
  end

  @doc """
  Decodes the wall-clock time for a block.

  `root` is the raw `parentBeaconBlockRoot`, accepted either as 32 raw bytes or
  as a `0x`-prefixed 64-character hex string. `height` selects the decoder
  version. `nil` root (pre-Cancun or absent field) yields `:decode_failed` with
  `error: :missing_root`.

  Always returns a `Result` — decoding never raises on malformed input, because
  a single bad block must not abort a backfill batch.
  """
  @spec decode(non_neg_integer(), binary() | nil) :: Result.t()
  def decode(height, root) when is_integer(height) and height >= 0 do
    version = version_for_height(height)

    if version in @supported_versions do
      do_decode(version, height, root)
    else
      %Result{status: :decode_failed, decoder_version: version, error: :unsupported_decoder_version}
    end
  end

  defp do_decode(version, _height, nil),
    do: %Result{status: :decode_failed, decoder_version: version, error: :missing_root}

  defp do_decode(version, height, root) do
    case normalize_root(root) do
      {:ok, bytes} -> decode_bytes(version, height, bytes)
      {:error, reason} -> %Result{status: :decode_failed, decoder_version: version, error: reason}
    end
  end

  # An all-zero root is only legitimate at a known genesis height. Treating it as
  # genesis at *any* height would silently convert an anomaly -- a node serving a
  # zeroed field, a pre-encoding block, an encoding change -- into a terminal
  # "no data here, nothing to retry", losing the row permanently and without a
  # signal. At an unexpected height it is a failure, which a later decoder
  # version may revisit.
  #
  # Whether heights other than 0 legitimately carry a zero root is protocol
  # question 4 and is not yet answered, so the set is configurable rather than
  # hardcoded to [0].
  defp decode_bytes(version, height, <<0::size(256)>>) do
    if height in genesis_heights() do
      %Result{status: :genesis, decoder_version: version}
    else
      %Result{status: :decode_failed, decoder_version: version, error: :unexpected_zero_root}
    end
  end

  defp decode_bytes(version, _height, <<
         block_count::size(@block_count_bits),
         first_daa_score::size(@first_daa_score_bits),
         raw_first_time_delta::size(@first_time_delta_bits),
         subsequent::bitstring
       >>) do
    first_time_delta = sign_extend(raw_first_time_delta)

    result = %Result{
      decoder_version: version,
      block_count: block_count,
      first_daa_score: first_daa_score,
      first_time_delta: first_time_delta,
      subsequent_deltas: subsequent_deltas(subsequent)
    }

    with :ok <- validate_block_count(block_count),
         {:ok, timestamp} <- recover_timestamp(first_daa_score, first_time_delta) do
      %Result{result | status: :ok, wall_clock_timestamp: timestamp}
    else
      {:error, reason} -> %Result{result | status: :decode_failed, error: reason}
    end
  end

  @doc """
  Returns the decoder version active at `height`.

  Selection is by height alone. Heights below the lowest configured activation
  fall back to version 1.
  """
  @spec version_for_height(non_neg_integer()) :: pos_integer()
  def version_for_height(height) when is_integer(height) and height >= 0 do
    decoder_activations()
    |> Enum.sort_by(fn {activation_height, _version} -> activation_height end)
    |> Enum.reduce(1, fn {activation_height, version}, active ->
      if height >= activation_height, do: version, else: active
    end)
  end

  @doc """
  Whether a recovered timestamp sits within `tolerance_seconds` of `now`.

  Intended for newly observed **head** blocks only, as a live alarm that the
  encoding or the anchor constants have shifted. Never apply it to historical
  backfill rows: correct history is arbitrarily far from the present.
  """
  @spec within_wall_clock_tolerance?(Result.t(), keyword()) :: boolean()
  def within_wall_clock_tolerance?(result, opts \\ [])

  def within_wall_clock_tolerance?(%Result{status: :ok, wall_clock_timestamp: %DateTime{} = timestamp}, opts) do
    tolerance = Keyword.get(opts, :tolerance_seconds, 120)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    abs(DateTime.diff(timestamp, now, :second)) <= tolerance
  end

  def within_wall_clock_tolerance?(%Result{}, _opts), do: false

  @doc """
  The synthetic timestamp Igra would derive for `daa_score`, in microseconds.

  Exposed for tests and for reconciling against `blocks.timestamp`.
  """
  @spec synthetic_unix_microseconds(non_neg_integer()) :: integer()
  def synthetic_unix_microseconds(daa_score) when is_integer(daa_score) do
    # Kept in integer deciseconds so no float ever enters the arithmetic: a
    # float here would introduce sub-second error across 13.9M rows.
    deciseconds = @ref_timestamp * @daa_per_second + (daa_score - @ref_daa_score)
    deciseconds * div(1_000_000, @daa_per_second)
  end

  defp recover_timestamp(first_daa_score, first_time_delta) do
    microseconds = synthetic_unix_microseconds(first_daa_score) + first_time_delta * 1_000_000

    if microseconds >= @min_plausible_unix * 1_000_000 and microseconds <= @max_plausible_unix * 1_000_000 do
      {:ok, DateTime.from_unix!(microseconds, :microsecond)}
    else
      {:error, :implausible_timestamp}
    end
  end

  # `block_count` counts the blocks the window describes: the first, plus up to
  # @subsequent_delta_count more. The 4-bit field can express 0..15, so values
  # outside 1..@max_block_count are structurally impossible and indicate the
  # layout has changed.
  defp validate_block_count(count) when count >= 1 and count <= @max_block_count, do: :ok
  defp validate_block_count(_count), do: {:error, :block_count_out_of_range}

  defp sign_extend(value) when value >= @first_time_delta_sign_bit, do: value - @first_time_delta_modulus
  defp sign_extend(value), do: value

  defp subsequent_deltas(bitstring) do
    for <<delta::size(@subsequent_delta_bits) <- bitstring>>, do: delta
  end

  defp normalize_root(<<_::binary-size(@root_bytes)>> = bytes), do: {:ok, bytes}

  defp normalize_root("0x" <> hex) when byte_size(hex) == @root_bytes * 2 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :malformed_root}
    end
  end

  defp normalize_root(root) when is_binary(root), do: {:error, :invalid_root_length}
  defp normalize_root(_root), do: {:error, :malformed_root}

  defp genesis_heights do
    :ethereum_jsonrpc
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:genesis_heights, [0])
  end

  defp decoder_activations do
    :ethereum_jsonrpc
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:decoder_activations, [{0, 1}])
  end
end
