# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.Block.WallClockStatusTest do
  use Explorer.DataCase, async: true

  alias Explorer.Chain.Block.WallClockStatus

  describe "value/1 and name/1" do
    test "the persisted numbers are pinned" do
      # These are stored in blocks.wall_clock_decode_status. Reassigning any of
      # them silently reinterprets every existing row, so they are asserted
      # literally rather than derived from the module.
      assert WallClockStatus.value(:pending) == 0
      assert WallClockStatus.value(:ok) == 1
      assert WallClockStatus.value(:no_root) == 2
      assert WallClockStatus.value(:decode_failed) == 3
      assert WallClockStatus.value(:orphan_unavailable) == 4
    end

    test "round-trips every status" do
      for status <- WallClockStatus.all() do
        assert status |> WallClockStatus.value() |> WallClockStatus.name() == status
      end
    end

    test "an unknown value degrades to nil rather than raising" do
      # A node reading rows written by a newer release may meet a status it does
      # not know. That must not crash a query.
      assert WallClockStatus.name(99) == nil
      assert WallClockStatus.name(-1) == nil
      assert WallClockStatus.name(nil) == nil
    end
  end

  describe "terminal?/1" do
    test "only :pending is non-terminal" do
      refute WallClockStatus.terminal?(:pending)

      for status <- WallClockStatus.all() -- [:pending] do
        assert WallClockStatus.terminal?(status), "#{status} should be terminal"
      end
    end
  end

  describe "without_timestamp/0" do
    test "every status except :ok leaves the timestamp NULL" do
      assert Enum.sort(WallClockStatus.without_timestamp()) ==
               Enum.sort(WallClockStatus.all() -- [:ok])
    end
  end

  describe "database constraints" do
    test "a block with no wall-clock fields is accepted" do
      # The all-NULL state is the entire existing table, so it must remain legal.
      assert %{wall_clock_decode_status: nil, wall_clock_timestamp: nil} = insert(:block)
    end

    test "rejects a timestamp without a status" do
      # The trap this guards: a CHECK evaluates to UNKNOWN on NULL and UNKNOWN
      # passes, so a constraint expressed only as `= 1` / `<> 1` would admit
      # this row. Every branch must pin the status explicitly.
      assert_raise Postgrex.Error, ~r/wall_clock_fields_consistent/, fn ->
        insert(:block, wall_clock_timestamp: DateTime.utc_now(), wall_clock_decode_status: nil)
      end
    end

    test "rejects :ok without a timestamp" do
      assert_raise Postgrex.Error, ~r/wall_clock_fields_consistent/, fn ->
        insert(:block,
          wall_clock_decode_status: WallClockStatus.value(:ok),
          wall_clock_timestamp: nil
        )
      end
    end

    test "rejects a terminal failure status carrying a timestamp" do
      for status <- [:no_root, :decode_failed, :orphan_unavailable] do
        assert_raise Postgrex.Error, ~r/wall_clock_fields_consistent/, fn ->
          insert(:block,
            wall_clock_decode_status: WallClockStatus.value(status),
            wall_clock_timestamp: DateTime.utc_now()
          )
        end
      end
    end

    test "accepts a fully populated :ok row" do
      block =
        insert(:block,
          wall_clock_decode_status: WallClockStatus.value(:ok),
          wall_clock_timestamp: DateTime.utc_now(),
          parent_beacon_block_root: :crypto.strong_rand_bytes(32),
          wall_clock_decoder_version: 1
        )

      assert WallClockStatus.name(block.wall_clock_decode_status) == :ok
    end

    test "rejects a root that is not exactly 32 bytes" do
      for bad <- [<<>>, :crypto.strong_rand_bytes(31), :crypto.strong_rand_bytes(33)] do
        assert_raise Postgrex.Error, ~r/parent_beacon_block_root_is_32_bytes/, fn ->
          insert(:block, parent_beacon_block_root: bad)
        end
      end
    end

    test "consensus timestamp is untouched by any of this" do
      # The whole design rests on blocks.timestamp remaining consensus data.
      timestamp = ~U[2026-08-12 12:00:00.000000Z]
      block = insert(:block, timestamp: timestamp)

      assert block.timestamp == timestamp
      assert is_nil(block.wall_clock_timestamp)
    end
  end
end
