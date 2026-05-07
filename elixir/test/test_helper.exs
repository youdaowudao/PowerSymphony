Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

ExUnit.start(SymphonyElixir.TestSupport.ex_unit_options())
