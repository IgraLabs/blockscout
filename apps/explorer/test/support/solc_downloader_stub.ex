# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Test.SolcDownloaderStub do
  @moduledoc """
  Test-time replacement for the parts of solc handling that reach the network.

  `Explorer.SmartContract.SolcDownloader.ensure_exists/1` downloads a compiler
  from `binaries.soliditylang.org` when it is not already on disk under
  `_build/<env>/lib/explorer/priv/solc_compilers/`. In CI that directory comes
  from the restored build cache, so whether a test needs the network depends on
  cache state rather than on anything in the test — which is why the solidity
  suites failed intermittently and unpredictably.

  Worse, the affected suites were `async: true` while setting
  `Application.put_env(:tesla, :adapter, ...)`, a **process-global** value. A
  concurrent test restoring the mock adapter mid-download produced
  `Mox.UnexpectedCallError` on a URL no test had stubbed.

  This module makes the dependency explicit. Tests that do not exercise real
  compilation use the stub and never touch the network; tests that genuinely
  compile are tagged `:compiler_download` and excluded from the default run.
  """

  @doc """
  Whether a compiler version is already present locally.

  Lets a test decide to skip rather than download.
  """
  @spec available?(String.t()) :: boolean()
  def available?(version) do
    File.exists?(path_for(version))
  end

  @doc """
  Path a compiler would occupy, without fetching it.
  """
  @spec path_for(String.t()) :: String.t()
  def path_for(version) do
    :explorer
    |> Application.app_dir("priv/solc_compilers/")
    |> Path.join("#{version}.js")
  end

  @doc """
  Stand-in for `SolcDownloader.ensure_exists/1` that never performs I/O.

  Returns the path when the compiler is already cached, and `false` otherwise —
  the same contract `ensure_exists/1` uses for an unavailable version, so
  callers need no special-casing.
  """
  @spec ensure_exists(String.t()) :: String.t() | false
  def ensure_exists(version) do
    if available?(version), do: path_for(version), else: false
  end

  @doc """
  Sets the Tesla adapter for the duration of a test and restores the **previous**
  value on exit.

  The existing suites hardcoded `Explorer.Mock.TeslaAdapter` in `on_exit`, which
  is not a restore — it is an assignment that happens to match the usual default.
  If anything else had changed it, that value was silently lost.

  Callers must be `async: false`. There is no way to scope a global setting to a
  process, so an async caller corrupts every concurrent test.
  """
  @spec put_tesla_adapter(module(), ((-> any()) -> any())) :: :ok
  def put_tesla_adapter(adapter, on_exit_fun) do
    previous = Application.get_env(:tesla, :adapter)
    Application.put_env(:tesla, :adapter, adapter)

    on_exit_fun.(fn ->
      case previous do
        nil -> Application.delete_env(:tesla, :adapter)
        value -> Application.put_env(:tesla, :adapter, value)
      end
    end)

    :ok
  end
end
