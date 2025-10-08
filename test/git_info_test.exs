defmodule ExZstdZig.GitInfoTest do
  use ExUnit.Case

  describe "git information" do
    test "returns version information" do
      assert is_binary(ExZstdZig.version())
      assert is_map(ExZstdZig.version_info())
      assert is_binary(ExZstdZig.version_string())
    end

    test "git info functions work" do
      info = ExZstdZig.GitInfo.info()

      assert is_map(info)
      assert Map.has_key?(info, :version)
      assert Map.has_key?(info, :commit_hash)
      assert Map.has_key?(info, :short_commit_hash)
      assert Map.has_key?(info, :branch)
      assert Map.has_key?(info, :status)
    end

    test "version string includes git information" do
      version_string = ExZstdZig.version_string()

      # Should contain version and git hash
      assert String.contains?(version_string, "0.1.0")
      assert String.contains?(version_string, "@")
    end
  end
end
