defmodule EthereumJSONRPC.Igra.WallClock.BlockParamsTest do
  use ExUnit.Case, async: true

  alias EthereumJSONRPC.Igra.WallClock
  alias EthereumJSONRPC.Igra.WallClock.BlockParams

  @env_key EthereumJSONRPC.Igra.WallClock

  # Real mainnet block 14,035,911. Decodes to +615 s of correction.
  @root "0x10079bef95c0004ce00000000000000000000000000000000000000000000000"
  @height 14_035_911

  @status_ok 1
  @status_no_root 2
  @status_decode_failed 3

  defp enable(value) do
    previous = Application.get_env(:ethereum_jsonrpc, @env_key, [])
    Application.put_env(:ethereum_jsonrpc, @env_key, Keyword.put(previous, :dual_write_enabled, value))
    on_exit(fn -> Application.put_env(:ethereum_jsonrpc, @env_key, previous) end)
  end

  defp elixir(number \\ @height, root \\ @root) do
    %{"number" => number, "parentBeaconBlockRoot" => root, "hash" => "0xabc"}
  end

  describe "disabled by default" do
    test "params pass through untouched" do
      # The single most important property: with the flag off, the import path
      # produces exactly what it produced before this module existed.
      params = %{number: @height, timestamp: ~U[2026-08-12 00:00:00.000000Z]}

      assert BlockParams.merge(params, elixir()) == params
    end

    test "enabled?/0 is false with no configuration at all" do
      previous = Application.get_env(:ethereum_jsonrpc, @env_key, [])
      Application.delete_env(:ethereum_jsonrpc, @env_key)
      on_exit(fn -> Application.put_env(:ethereum_jsonrpc, @env_key, previous) end)

      refute BlockParams.enabled?()
    end

    test "adds no keys even when the root would decode cleanly" do
      assert BlockParams.merge(%{}, elixir()) == %{}
    end
  end

  describe "enabled" do
    setup do
      enable(true)
      :ok
    end

    test "a decodable block gets timestamp, root, status ok and version" do
      params = BlockParams.merge(%{}, elixir())

      assert params.wall_clock_decode_status == @status_ok
      assert params.wall_clock_decoder_version == 1
      assert %DateTime{} = params.wall_clock_timestamp
      assert byte_size(params.parent_beacon_block_root) == 32
    end

    test "the recovered time matches the decoder" do
      %WallClock.Result{wall_clock_timestamp: expected} = WallClock.decode(@height, @root)

      assert BlockParams.merge(%{}, elixir()).wall_clock_timestamp == expected
    end

    test "existing params are preserved" do
      params = BlockParams.merge(%{number: @height, timestamp: ~U[2026-01-01 00:00:00.000000Z]}, elixir())

      assert params.number == @height
      assert params.timestamp == ~U[2026-01-01 00:00:00.000000Z]
    end

    test "an absent root is no_root, not a failure" do
      params = BlockParams.merge(%{}, %{"number" => @height})

      assert params.wall_clock_decode_status == @status_no_root
      assert is_nil(params.wall_clock_timestamp)
      assert is_nil(params.parent_beacon_block_root)
    end

    test "an all-zero root at genesis is no_root" do
      zero = "0x" <> String.duplicate("0", 64)
      params = BlockParams.merge(%{}, elixir(0, zero))

      assert params.wall_clock_decode_status == @status_no_root
      assert is_nil(params.wall_clock_timestamp)
    end

    test "an all-zero root above genesis is a decode failure, not no_root" do
      # Distinguishing these is the point of the zero-root handling: an anomaly
      # must not be recorded as a legitimate absence.
      zero = "0x" <> String.duplicate("0", 64)
      params = BlockParams.merge(%{}, elixir(@height, zero))

      assert params.wall_clock_decode_status == @status_decode_failed
    end

    test "a malformed root fails without raising and stores no root" do
      for bad <- ["0xzz", "0x", "not-hex", "0x" <> String.duplicate("ab", 31)] do
        params = BlockParams.merge(%{}, elixir(@height, bad))

        assert params.wall_clock_decode_status == @status_decode_failed,
               "#{inspect(bad)} should be a decode failure"

        assert is_nil(params.wall_clock_timestamp)
        assert is_nil(params.parent_beacon_block_root)
      end
    end

    test "a failed decode still retains a well-formed root" do
      # 32 valid bytes whose block_count is 0, which the decoder rejects. The
      # root is the evidence for diagnosing the failure and lets a later decoder
      # version retry without re-fetching the block.
      root = "0x00" <> String.duplicate("11", 31)
      params = BlockParams.merge(%{}, elixir(@height, root))

      assert params.wall_clock_decode_status == @status_decode_failed
      assert byte_size(params.parent_beacon_block_root) == 32
    end

    test "a missing block number is a failure, never a guessed version" do
      # Decoder version is selected by height. Without a height there is nothing
      # to select on, and defaulting to v1 would silently mis-decode after a fork.
      params = BlockParams.merge(%{}, %{"parentBeaconBlockRoot" => @root})

      assert params.wall_clock_decode_status == @status_decode_failed
      assert is_nil(params.wall_clock_timestamp)
    end

    test "never emits a timestamp alongside a non-ok status" do
      # Mirrors the database CHECK: only status ok carries a timestamp.
      for elixir <- [
            %{"number" => @height},
            elixir(0, "0x" <> String.duplicate("0", 64)),
            elixir(@height, "0xzz"),
            %{"parentBeaconBlockRoot" => @root}
          ] do
        params = BlockParams.merge(%{}, elixir)

        if params.wall_clock_decode_status != @status_ok do
          assert is_nil(params.wall_clock_timestamp), "status #{params.wall_clock_decode_status} carried a timestamp"
        end
      end
    end
  end

  describe "timestamp_for/1 -- the value stamped onto a block's transactions" do
    test "nil while disabled, so transactions are untouched" do
      enable(false)
      assert BlockParams.timestamp_for(elixir()) == nil
    end

    test "matches the block's own wall_clock_timestamp exactly" do
      enable(true)

      # A transaction carrying a different instant from its own block would be
      # worse than carrying none: it would look authoritative and be wrong.
      assert BlockParams.timestamp_for(elixir()) == BlockParams.merge(%{}, elixir()).wall_clock_timestamp
    end

    test "nil for every non-ok outcome, never a partial value" do
      enable(true)

      for elixir <- [
            %{"number" => @height},
            elixir(@height, "0xzz"),
            elixir(@height, "0x" <> String.duplicate("0", 64)),
            %{"parentBeaconBlockRoot" => @root}
          ] do
        assert BlockParams.timestamp_for(elixir) == nil, "#{inspect(elixir)} should yield nil"
      end
    end

    test "genesis yields nil rather than a timestamp" do
      enable(true)
      assert BlockParams.timestamp_for(elixir(0, "0x" <> String.duplicate("0", 64))) == nil
    end
  end

  describe "telemetry" do
    setup do
      enable(true)
      :ok
    end

    test "emits one event per block with bounded metadata" do
      handler = "test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ethereum_jsonrpc, :igra, :wall_clock, :decode],
        fn _event, measurements, metadata, _config -> send(test_pid, {:telemetry, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      BlockParams.merge(%{}, elixir())

      assert_receive {:telemetry, %{count: 1}, metadata}
      assert metadata.status == :ok
      assert metadata.decoder_version == 1

      # Block number and hash must never appear: unbounded label values would
      # blow up any metrics backend aggregating on them.
      refute Map.has_key?(metadata, :number)
      refute Map.has_key?(metadata, :hash)
    end

    test "reports the error atom on failure" do
      handler = "test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ethereum_jsonrpc, :igra, :wall_clock, :decode],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      BlockParams.merge(%{}, %{"number" => @height})

      assert_receive {:telemetry, %{status: :decode_failed, error: :missing_root}}
    end

    test "no events at all while disabled" do
      enable(false)

      handler = "test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ethereum_jsonrpc, :igra, :wall_clock, :decode],
        fn _event, _m, _md, _c -> send(test_pid, :telemetry) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      BlockParams.merge(%{}, elixir())

      refute_receive :telemetry, 100
    end
  end

  describe "kill switch" do
    test "flipping the flag at runtime takes effect on the next block" do
      enable(true)
      assert BlockParams.merge(%{}, elixir()) != %{}

      previous = Application.get_env(:ethereum_jsonrpc, @env_key, [])
      Application.put_env(:ethereum_jsonrpc, @env_key, Keyword.put(previous, :dual_write_enabled, false))

      # No restart, no redeploy: the very next block is unaffected.
      assert BlockParams.merge(%{}, elixir()) == %{}
    end
  end
end
