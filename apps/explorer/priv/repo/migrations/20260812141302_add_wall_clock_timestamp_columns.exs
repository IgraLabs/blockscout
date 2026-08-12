# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Repo.Migrations.AddWallClockTimestampColumns do
  @moduledoc """
  Adds the columns that carry Igra's recovered wall-clock time.

  Purely additive and nullable. Nothing writes these yet and nothing reads them;
  `blocks.timestamp` and `transactions.block_timestamp` are untouched, because
  they are consensus data and must never be overwritten.

  All columns are nullable with no default, so PostgreSQL records a catalog-only
  change and does not rewrite either table -- important on `blocks` (~15M rows)
  and `transactions`.

  The CHECK constraints are added `NOT VALID` so they bind new and updated rows
  immediately without scanning existing ones. They are validated in a later
  migration, after the backfill, and only then can the status column be made
  `NOT NULL`.
  """

  use Ecto.Migration

  # Matches Explorer.Chain.Block.WallClockStatus. A smallint plus a CHECK is used
  # rather than a PostgreSQL enum so a rolling upgrade can introduce a new status
  # without an ALTER TYPE that older nodes cannot read.
  #
  #   0 pending             not yet decoded/backfilled
  #   1 ok                  decoded and validated
  #   2 no_root             root absent, or a known genesis special case
  #   3 decode_failed       root present but invalid or unsupported
  #   4 orphan_unavailable  non-canonical block, root not retrievable
  @statuses_without_timestamp [2, 3, 4]

  def up do
    alter table(:blocks) do
      add(:wall_clock_timestamp, :"timestamp without time zone", null: true)
      add(:parent_beacon_block_root, :bytea, null: true)
      add(:wall_clock_decode_status, :smallint, null: true)
      add(:wall_clock_decoder_version, :smallint, null: true)
    end

    alter table(:transactions) do
      add(:wall_clock_timestamp, :"timestamp without time zone", null: true)
    end

    create(
      constraint(:blocks, :parent_beacon_block_root_is_32_bytes,
        check: "parent_beacon_block_root IS NULL OR octet_length(parent_beacon_block_root) = 32",
        validate: false
      )
    )

    # Every branch pins wall_clock_decode_status explicitly, including the
    # all-NULL one. A CHECK evaluates to UNKNOWN on NULL and UNKNOWN passes, so a
    # constraint written only in terms of `= 1` / `<> 1` would silently admit
    # rows with a NULL status and a non-NULL timestamp.
    create(
      constraint(:blocks, :wall_clock_fields_consistent,
        check: """
        (wall_clock_decode_status IS NULL
           AND wall_clock_timestamp IS NULL
           AND wall_clock_decoder_version IS NULL)
        OR (wall_clock_decode_status = 0 AND wall_clock_timestamp IS NULL)
        OR (wall_clock_decode_status = 1
           AND wall_clock_timestamp IS NOT NULL
           AND parent_beacon_block_root IS NOT NULL
           AND wall_clock_decoder_version IS NOT NULL)
        OR (wall_clock_decode_status IN (#{Enum.join(@statuses_without_timestamp, ", ")})
           AND wall_clock_timestamp IS NULL)
        """,
        validate: false
      )
    )
  end

  def down do
    drop(constraint(:blocks, :wall_clock_fields_consistent))
    drop(constraint(:blocks, :parent_beacon_block_root_is_32_bytes))

    alter table(:transactions) do
      remove(:wall_clock_timestamp)
    end

    alter table(:blocks) do
      remove(:wall_clock_decoder_version)
      remove(:wall_clock_decode_status)
      remove(:parent_beacon_block_root)
      remove(:wall_clock_timestamp)
    end
  end
end
