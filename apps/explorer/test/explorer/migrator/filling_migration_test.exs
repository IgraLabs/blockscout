# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Migrator.FillingMigrationTest do
  use Explorer.DataCase, async: false

  alias Explorer.Migrator.MigrationStatus

  # Each migration below drives `handle_info(:migrate_batch, state)` directly. That
  # is the whole decision surface of the behaviour, and calling it in the test
  # process keeps the Ecto sandbox connection and lets `update_cache/0` observe
  # what the database looked like at the instant it ran.

  defmodule Plain do
    @moduledoc false
    use Explorer.Migrator.FillingMigration

    def migration_name, do: "test_filling_migration_plain"
    def unprocessed_data_query, do: nil
    def last_unprocessed_identifiers(state), do: {[], state}
    def update_batch(_batch), do: :ok

    # Records the durable status as seen at cache-refresh time. If the status is
    # written first, this observes "completed".
    def update_cache do
      Process.put(:status_at_cache_update, MigrationStatus.get_status(migration_name()))
    end
  end

  defmodule Working do
    @moduledoc false
    use Explorer.Migrator.FillingMigration

    def migration_name, do: "test_filling_migration_working"
    def unprocessed_data_query, do: nil
    def last_unprocessed_identifiers(state), do: {[1, 2, 3], Map.put(state, :seen, true)}
    def update_batch(batch), do: Process.put(:batch, batch)
    def update_cache, do: Process.put(:cache_updated, true)
  end

  # Reports no remaining work -- which the behaviour otherwise treats as "done" --
  # while actually only wanting to pause.
  defmodule Deferring do
    @moduledoc false
    use Explorer.Migrator.FillingMigration

    def migration_name, do: "test_filling_migration_deferring"
    def unprocessed_data_query, do: nil
    def last_unprocessed_identifiers(state), do: {[], state}
    def update_batch(_batch), do: :ok
    def update_cache, do: Process.put(:cache_updated, true)

    def batch_readiness, do: {:defer, 25}
  end

  defmodule Rejecting do
    @moduledoc false
    use Explorer.Migrator.FillingMigration

    def migration_name, do: "test_filling_migration_rejecting"
    def unprocessed_data_query, do: nil
    def last_unprocessed_identifiers(state), do: {[], state}
    def update_batch(_batch), do: :ok
    def update_cache, do: Process.put(:cache_updated, true)

    def validate_completion, do: {:error, :head_not_finalized}
  end

  defmodule Slow do
    @moduledoc false
    use Explorer.Migrator.FillingMigration

    def migration_name, do: "test_filling_migration_slow"
    def unprocessed_data_query, do: nil
    def last_unprocessed_identifiers(state), do: {[1], state}
    def update_batch(_batch), do: Process.sleep(:timer.seconds(30))
    def update_cache, do: :ok
  end

  describe "existing migrations are unaffected" do
    test "a migration defining no safety hooks still completes" do
      assert {:stop, :normal, _state} = Plain.handle_info(:migrate_batch, %{})

      assert MigrationStatus.get_status(Plain.migration_name()) == "completed"
    end

    test "the batch path still processes and checkpoints" do
      # update_meta/2 is a no-op when the migration row does not exist yet, so the
      # row has to be started before a checkpoint can be observed.
      MigrationStatus.set_status(Working.migration_name(), "started")

      assert {:noreply, %{seen: true}} = Working.handle_info(:migrate_batch, %{})

      assert Process.get(:batch) == [1, 2, 3]
      assert %{meta: %{"seen" => true}} = MigrationStatus.fetch(Working.migration_name())

      refute MigrationStatus.get_status(Working.migration_name()) == "completed"
    end

    test "the hooks default to :ready and :ok" do
      assert Plain.batch_readiness() == :ready
      assert Plain.validate_completion() == :ok
    end
  end

  describe "completion ordering" do
    test "the durable status is written before the cache is refreshed" do
      Plain.handle_info(:migrate_batch, %{})

      assert Process.get(:status_at_cache_update) == "completed", """
      update_cache/0 ran before the status was durable. A crash in that window leaves \
      the cache reporting a migration the database does not have as completed, sending \
      readers down the post-migration code path against un-migrated data. The reverse \
      order only ever costs a fallback path.
      """
    end
  end

  describe "batch_readiness/0" do
    test "deferring does not complete the migration" do
      assert {:noreply, %{}} = Deferring.handle_info(:migrate_batch, %{})

      refute MigrationStatus.get_status(Deferring.migration_name()) == "completed"
      refute Process.get(:cache_updated)
    end

    test "deferring reschedules the batch" do
      Deferring.handle_info(:migrate_batch, %{})

      assert_receive :migrate_batch, 500
    end
  end

  describe "validate_completion/0" do
    test "a rejected completion is not made permanent" do
      assert {:noreply, %{}} = Rejecting.handle_info(:migrate_batch, %{})

      refute MigrationStatus.get_status(Rejecting.migration_name()) == "completed"
      refute Process.get(:cache_updated)
    end

    test "a rejected completion reschedules rather than stopping" do
      Application.put_env(:explorer, Rejecting, completion_retry_interval: 10)
      on_exit(fn -> Application.delete_env(:explorer, Rejecting) end)

      assert {:noreply, _state} = Rejecting.handle_info(:migrate_batch, %{})
      assert_receive :migrate_batch, 500
    end
  end

  describe "task_timeout" do
    test "defaults to :infinity, so batch durations are unchanged" do
      assert is_nil(Application.get_env(:explorer, Slow))
    end

    test "a configured timeout bounds a hung batch instead of wedging forever" do
      Application.put_env(:explorer, Slow, task_timeout: 50)
      on_exit(fn -> Application.delete_env(:explorer, Slow) end)

      # Task.await_many/2 exits the caller on timeout, so run it off the test
      # process. Under the previous unconditional :infinity this never returns.
      Process.flag(:trap_exit, true)
      pid = spawn_link(fn -> Slow.handle_info(:migrate_batch, %{}) end)

      assert_receive {:EXIT, ^pid, {:timeout, _}}, 5_000
    end
  end
end
