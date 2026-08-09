defmodule Explorer.Repo.Migrations.WithdrawalsChangeIndexTypesToNumeric do
  use Ecto.Migration

  def change do
    alter table(:withdrawals) do
      modify(:index, :numeric, precision: 20, scale: 0, primary_key: true)
      modify(:validator_index, :numeric, precision: 20, scale: 0)
    end
  end
end
