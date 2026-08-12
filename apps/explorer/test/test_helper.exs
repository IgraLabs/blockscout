# SPDX-License-Identifier: LicenseRef-Blockscout
# https://github.com/CircleCI-Public/circleci-demo-elixir-phoenix/blob/a89de33a01df67b6773ac90adc74c34367a4a2d6/test/test_helper.exs#L1-L3
junit_folder = Mix.Project.build_path() <> "/junit/#{Mix.Project.config()[:app]}"
File.mkdir_p!(junit_folder)
:ok = Application.put_env(:junit_formatter, :report_dir, junit_folder)

# Counter `test --no-start`.  `--no-start` is needed for `:indexer` compatibility
{:ok, _} = Application.ensure_all_started(:explorer)

# :compiler_download marks suites that compile Solidity for real. They need a solc
# binary and fetch it from binaries.soliditylang.org when the build cache does
# not already hold it, which made them fail unpredictably in CI on cache state
# rather than on anything in the code under test.
#
# They are excluded by default and NOT deleted -- run them deliberately with:
#
#     mix test --include compiler_download
#
# CI runs them on a schedule rather than per-PR, so a genuine regression in
# verification is still caught, just not on a path where a cold cache can block
# an unrelated change.
ExUnit.configure(
  formatters: [JUnitFormatter, ExUnit.CLIFormatter],
  exclude: [:compiler_download]
)

ExUnit.start()

{:ok, _} = Application.ensure_all_started(:ex_machina)

Explorer.TestHelper.run_necessary_background_migrations()

Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Account, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.PolygonEdge, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.RSK, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Shibarium, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Suave, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Beacon, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.BridgedTokens, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Filecoin, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Stability, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.Mud, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.ShrunkInternalTransactions, :auto)
Ecto.Adapters.SQL.Sandbox.mode(Explorer.Repo.EventNotifications, :auto)

Mox.defmock(Explorer.Market.Source.TestSource, for: Explorer.Market.Source)
Mox.defmock(Explorer.History.TestHistorian, for: Explorer.History.Historian)

Mox.defmock(EthereumJSONRPC.Mox, for: EthereumJSONRPC.Transport)

Mox.defmock(Explorer.Mock.TeslaAdapter, for: Tesla.Adapter)
