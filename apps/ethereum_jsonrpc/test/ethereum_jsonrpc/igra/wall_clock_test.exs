defmodule EthereumJSONRPC.Igra.WallClockTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias EthereumJSONRPC.Igra.WallClock
  alias EthereumJSONRPC.Igra.WallClock.Result

  @env_key EthereumJSONRPC.Igra.WallClock

  # Bit widths, mirrored here on purpose: if the production module changes a
  # width, these fixtures must fail rather than silently follow it.
  @block_count_bits 4
  @first_daa_score_bits 38
  @first_time_delta_bits 25
  @subsequent_delta_bits 21
  @subsequent_delta_count 9

  @ref_daa_score 365_578_320
  @ref_timestamp 1_771_977_542

  @max_delta (1 <<< (@first_time_delta_bits - 1)) - 1
  @min_delta -(1 <<< (@first_time_delta_bits - 1))

  # Real mainnet blocks. `wall_us` was produced by an independent Python
  # decoder (pure integer bit-slicing, no shared code with the module under
  # test) reading these blocks from https://igra-mainnet.jobberwocky.co.
  @fixtures [
    %{
      height: 1,
      root: "0x1005744169400009a00000000000000000000000000000000000000000000000",
      synthetic_ts: 1_772_021_710,
      block_count: 1,
      first_daa_score: 366_020_005,
      first_time_delta: 77,
      wall_us: 1_772_021_787_500_000
    },
    %{
      height: 1_000_000,
      root: "0x10059bd2f73ffffde00000000000000000000000000000000000000000000000",
      synthetic_ts: 1_773_058_976,
      block_count: 1,
      first_daa_score: 376_392_668,
      first_time_delta: -17,
      wall_us: 1_773_058_959_800_000
    },
    %{
      height: 7_000_000,
      root: "0x100688c99b3ffff4200000000000000000000000000000000000000000000000",
      synthetic_ts: 1_779_270_831,
      block_count: 1,
      first_daa_score: 438_511_212,
      first_time_delta: -95,
      wall_us: 1_779_270_736_200_000
    },
    %{
      height: 13_000_000,
      root: "0x200772e8f4400052a00001000000000000000000000000000000000000000000",
      synthetic_ts: 1_785_408_210,
      block_count: 2,
      first_daa_score: 499_885_009,
      first_time_delta: 661,
      wall_us: 1_785_408_871_900_000
    },
    %{
      height: 14_035_911,
      root: "0x10079bef95c0004ce00000000000000000000000000000000000000000000000",
      synthetic_ts: 1_786_483_680,
      block_count: 1,
      first_daa_score: 510_639_703,
      first_time_delta: 615,
      wall_us: 1_786_484_295_300_000
    }
  ]

  describe "decode/2 against real mainnet blocks" do
    test "agrees with the independent decoder on every field" do
      for fixture <- @fixtures do
        assert %Result{
                 status: :ok,
                 decoder_version: 1,
                 block_count: block_count,
                 first_daa_score: first_daa_score,
                 first_time_delta: first_time_delta,
                 wall_clock_timestamp: timestamp
               } = WallClock.decode(fixture.height, fixture.root),
               "height #{fixture.height} failed to decode"

        assert block_count == fixture.block_count, "block_count at height #{fixture.height}"
        assert first_daa_score == fixture.first_daa_score, "first_daa_score at height #{fixture.height}"
        assert first_time_delta == fixture.first_time_delta, "first_time_delta at height #{fixture.height}"

        assert DateTime.to_unix(timestamp, :microsecond) == fixture.wall_us,
               "wall clock at height #{fixture.height}"
      end
    end

    test "recovered time is ahead of the synthetic timestamp on recent blocks" do
      # The synthetic clock runs behind wall time and the gap widens, so recent
      # blocks must decode to a *later* instant than blocks.timestamp. This is
      # the whole premise of the correction.
      recent = Enum.find(@fixtures, &(&1.height == 14_035_911))

      assert %Result{status: :ok, wall_clock_timestamp: timestamp} = WallClock.decode(recent.height, recent.root)

      drift_seconds = DateTime.to_unix(timestamp) - recent.synthetic_ts

      assert drift_seconds > 600, "expected the head to be >10 min behind wall clock, got #{drift_seconds}s"
    end

    test "accepts raw 32-byte roots as well as hex strings" do
      fixture = hd(@fixtures)
      "0x" <> hex = fixture.root
      raw = Base.decode16!(hex, case: :mixed)

      assert WallClock.decode(fixture.height, raw) == WallClock.decode(fixture.height, fixture.root)
    end
  end

  describe "decode/2 signed delta handling" do
    test "sign-extends the boundary values" do
      for delta <- [@min_delta, -1, 0, 1, @max_delta] do
        assert %Result{status: status, first_time_delta: decoded} =
                 WallClock.decode(1, root(1, @ref_daa_score, delta))

        assert decoded == delta, "delta #{delta} did not round-trip"
        assert status == :ok, "delta #{delta} produced #{status}"
      end
    end

    test "the delta shifts the recovered time by exactly that many seconds" do
      base = WallClock.decode(1, root(1, @ref_daa_score, 0))

      for delta <- [@min_delta, -95, -1, 1, 77, @max_delta] do
        result = WallClock.decode(1, root(1, @ref_daa_score, delta))

        assert DateTime.diff(result.wall_clock_timestamp, base.wall_clock_timestamp, :second) == delta
      end
    end

    test "a zero delta at the reference DAA score recovers the reference timestamp" do
      assert %Result{status: :ok, wall_clock_timestamp: timestamp} =
               WallClock.decode(1, root(1, @ref_daa_score, 0))

      assert DateTime.to_unix(timestamp) == @ref_timestamp
    end

    test "sub-second DAA offsets are preserved exactly" do
      # One DAA increment is 100ms. Integer arithmetic must carry it without
      # float error.
      for offset <- 1..9 do
        assert %Result{status: :ok, wall_clock_timestamp: timestamp} =
                 WallClock.decode(1, root(1, @ref_daa_score + offset, 0))

        assert DateTime.to_unix(timestamp, :microsecond) == @ref_timestamp * 1_000_000 + offset * 100_000
      end
    end
  end

  describe "decode/2 block_count validation" do
    test "accepts the full documented range" do
      for count <- 1..10 do
        assert %Result{status: :ok, block_count: ^count} = WallClock.decode(1, root(count, @ref_daa_score, 0))
      end
    end

    test "rejects counts the layout cannot describe" do
      # The field is 4 bits (0..15) but only 10 delta slots exist, so 0 and
      # 11..15 mean the layout has changed under us.
      for count <- [0, 11, 15] do
        assert %Result{status: :decode_failed, error: :block_count_out_of_range} =
                 WallClock.decode(1, root(count, @ref_daa_score, 0))
      end
    end

    test "a failed decode still reports the fields it parsed" do
      assert %Result{status: :decode_failed, block_count: 0, first_daa_score: @ref_daa_score, first_time_delta: 5} =
               WallClock.decode(1, root(0, @ref_daa_score, 5))
    end
  end

  describe "decode/2 genesis and malformed input" do
    test "the all-zero root is genesis at height 0" do
      zero = "0x" <> String.duplicate("0", 64)

      assert %Result{status: :genesis, decoder_version: 1, wall_clock_timestamp: nil} = WallClock.decode(0, zero)
      assert %Result{status: :genesis} = WallClock.decode(0, <<0::size(256)>>)
    end

    test "an all-zero root above genesis is a failure, not genesis" do
      # Treating it as :genesis at any height silently converts an anomaly into a
      # terminal "no data here", losing the row permanently and with no signal.
      for height <- [1, 1_000_000, 14_077_309] do
        assert %Result{status: :decode_failed, error: :unexpected_zero_root} =
                 WallClock.decode(height, <<0::size(256)>>),
               "height #{height} treated a zero root as genesis"
      end
    end

    test "additional genesis heights are configurable" do
      # Whether heights other than 0 legitimately carry a zero root is protocol
      # question 4, still unanswered -- so it must be settable without a code change.
      previous = Application.get_env(:ethereum_jsonrpc, @env_key, [])
      Application.put_env(:ethereum_jsonrpc, @env_key, Keyword.put(previous, :genesis_heights, [0, 42]))
      on_exit(fn -> Application.put_env(:ethereum_jsonrpc, @env_key, previous) end)

      assert %Result{status: :genesis} = WallClock.decode(42, <<0::size(256)>>)
      assert %Result{status: :genesis} = WallClock.decode(0, <<0::size(256)>>)
      assert %Result{status: :decode_failed, error: :unexpected_zero_root} = WallClock.decode(43, <<0::size(256)>>)
    end

    test "a non-zero root at height 0 still decodes normally" do
      # Genesis is defined by the zero root, not by the height alone.
      assert %Result{status: :ok} = WallClock.decode(0, root(1, @ref_daa_score, 0))
    end

    test "a nil root fails without raising" do
      assert %Result{status: :decode_failed, error: :missing_root} = WallClock.decode(1, nil)
    end

    test "wrong-length roots fail without raising" do
      for root <- ["0x", "0xdeadbeef", "0x" <> String.duplicate("ab", 31), "0x" <> String.duplicate("ab", 33)] do
        assert %Result{status: :decode_failed, error: error} = WallClock.decode(1, root)
        assert error in [:invalid_root_length, :malformed_root]
      end
    end

    test "non-hex characters fail without raising" do
      assert %Result{status: :decode_failed, error: :malformed_root} =
               WallClock.decode(1, "0x" <> String.duplicate("zz", 32))
    end

    test "non-binary input fails without raising" do
      assert %Result{status: :decode_failed, error: :malformed_root} = WallClock.decode(1, 12_345)
    end

    test "an implausible recovered timestamp is rejected" do
      # Maximum expressible DAA score lands in the year ~2896.
      max_daa = (1 <<< @first_daa_score_bits) - 1

      assert %Result{status: :decode_failed, error: :implausible_timestamp} =
               WallClock.decode(1, root(1, max_daa, 0))
    end
  end

  describe "version_for_height/1" do
    test "defaults to version 1 at every height" do
      for height <- [0, 1, 14_035_911, 999_999_999] do
        assert WallClock.version_for_height(height) == 1
      end
    end

    test "selects by height, not by payload" do
      put_activations([{0, 1}, {100, 2}, {200, 3}])

      assert WallClock.version_for_height(0) == 1
      assert WallClock.version_for_height(99) == 1
      assert WallClock.version_for_height(100) == 2
      assert WallClock.version_for_height(199) == 2
      assert WallClock.version_for_height(200) == 3
      assert WallClock.version_for_height(1_000_000) == 3
    end

    test "is insensitive to the order activations are configured in" do
      put_activations([{200, 3}, {0, 1}, {100, 2}])

      assert WallClock.version_for_height(150) == 2
      assert WallClock.version_for_height(250) == 3
    end

    test "heights below the lowest activation fall back to version 1" do
      put_activations([{500, 2}])

      assert WallClock.version_for_height(499) == 1
      assert WallClock.version_for_height(500) == 2
    end
  end

  describe "decode/2 version gating" do
    test "refuses to decode under a version it does not implement" do
      put_activations([{0, 1}, {100, 2}])

      fixture = hd(@fixtures)

      assert %Result{status: :decode_failed, decoder_version: 2, error: :unsupported_decoder_version} =
               WallClock.decode(100, fixture.root)

      # ...and the same payload still decodes below the fork height.
      assert %Result{status: :ok, decoder_version: 1} = WallClock.decode(99, fixture.root)
    end
  end

  describe "within_wall_clock_tolerance?/2" do
    test "true when the recovered time is close to now" do
      result = WallClock.decode(1, root(1, @ref_daa_score, 0))
      now = DateTime.from_unix!(@ref_timestamp + 30)

      assert WallClock.within_wall_clock_tolerance?(result, now: now, tolerance_seconds: 120)
    end

    test "false when the recovered time is far from now" do
      result = WallClock.decode(1, root(1, @ref_daa_score, 0))
      now = DateTime.from_unix!(@ref_timestamp + 3600)

      refute WallClock.within_wall_clock_tolerance?(result, now: now, tolerance_seconds: 120)
    end

    test "symmetric around now" do
      result = WallClock.decode(1, root(1, @ref_daa_score, 0))

      assert WallClock.within_wall_clock_tolerance?(result,
               now: DateTime.from_unix!(@ref_timestamp - 30),
               tolerance_seconds: 120
             )
    end

    test "false for any non-ok result" do
      refute WallClock.within_wall_clock_tolerance?(WallClock.decode(0, <<0::size(256)>>))
      refute WallClock.within_wall_clock_tolerance?(WallClock.decode(1, nil))
    end
  end

  describe "synthetic_unix_microseconds/1" do
    test "reproduces blocks.timestamp for real blocks" do
      # The chain's own synthetic clock, recomputed from the decoded DAA score,
      # must match the timestamp the chain published (to within the 100ms DAA
      # granularity, since blocks.timestamp is whole seconds).
      for fixture <- @fixtures do
        %Result{first_daa_score: daa} = WallClock.decode(fixture.height, fixture.root)

        synthetic_seconds = div(WallClock.synthetic_unix_microseconds(daa), 1_000_000)

        assert abs(synthetic_seconds - fixture.synthetic_ts) <= 1,
               "height #{fixture.height}: recomputed #{synthetic_seconds} vs published #{fixture.synthetic_ts}"
      end
    end

    test "uses integer arithmetic throughout" do
      assert is_integer(WallClock.synthetic_unix_microseconds(@ref_daa_score))
      assert WallClock.synthetic_unix_microseconds(@ref_daa_score) == @ref_timestamp * 1_000_000
      assert WallClock.synthetic_unix_microseconds(@ref_daa_score + 1) == @ref_timestamp * 1_000_000 + 100_000
    end
  end

  describe "subsequent_deltas" do
    test "are surfaced raw for diagnostics" do
      deltas = [1, 2, 3, 4, 5, 6, 7, 8, 9]

      assert %Result{subsequent_deltas: ^deltas} = WallClock.decode(1, root(10, @ref_daa_score, 0, deltas))
    end

    test "do not influence the recovered timestamp" do
      # They are unvalidated by the protocol owners, so nothing may depend on
      # them. Changing them must not move the answer.
      quiet = WallClock.decode(1, root(1, @ref_daa_score, 0, List.duplicate(0, 9)))
      noisy = WallClock.decode(1, root(1, @ref_daa_score, 0, List.duplicate(2_097_151, 9)))

      assert quiet.wall_clock_timestamp == noisy.wall_clock_timestamp
    end
  end

  # Builds a 32-byte root from field values, MSB-first.
  defp root(block_count, first_daa_score, delta, subsequent \\ List.duplicate(0, @subsequent_delta_count)) do
    raw_delta =
      if delta < 0, do: delta + (1 <<< @first_time_delta_bits), else: delta

    subsequent_bits =
      Enum.reduce(subsequent, <<>>, fn value, acc -> <<acc::bitstring, value::size(@subsequent_delta_bits)>> end)

    <<block_count::size(@block_count_bits), first_daa_score::size(@first_daa_score_bits),
      raw_delta::size(@first_time_delta_bits), subsequent_bits::bitstring>>
  end

  defp put_activations(activations) do
    previous = Application.get_env(:ethereum_jsonrpc, @env_key, [])

    Application.put_env(
      :ethereum_jsonrpc,
      @env_key,
      Keyword.put(previous, :decoder_activations, activations)
    )

    on_exit(fn -> Application.put_env(:ethereum_jsonrpc, @env_key, previous) end)
  end
end
