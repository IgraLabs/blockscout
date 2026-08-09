defmodule Explorer.Repo.Migrations.WithdrawalsChangeIndexTypesToNumeric do
  use Ecto.Migration

  def up do
    alter table(:withdrawals) do
      modify(:index, :numeric, precision: 20, scale: 0)
      modify(:validator_index, :numeric, precision: 20, scale: 0)
    end
  end

  def down do
    alter table(:withdrawals) do
      modify(:index, :integer)
      modify(:validator_index, :integer)
    end
  end
end
