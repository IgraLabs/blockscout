defmodule Explorer.Repo.Migrations.WithdrawalsChangeIndexTypesToNumeric do
  use Ecto.Migration

  # EIP-4895 withdrawal index and validator_index are uint64; upstream declares
  # them as int32, which overflows on Igra. Widen both to numeric(20,0).
  #
  # Note: do NOT pass `primary_key: true` here. `index` is already the primary
  # key from CreateWithdrawals; Ecto would emit an additional ADD PRIMARY KEY,
  # which fails on a fresh database with
  #   ERROR 42P16 multiple primary keys for table "withdrawals" are not allowed
  # Changing the column type does not affect the existing primary key.
  def change do
    alter table(:withdrawals) do
      modify(:index, :numeric, precision: 20, scale: 0)
      modify(:validator_index, :numeric, precision: 20, scale: 0)
    end
  end
end
