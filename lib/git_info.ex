defmodule ExZstdZig.GitInfo do
  @moduledoc """
  Provides git repository information for the ExZstdZig project.
  """

  @doc """
  Returns the current git commit hash.
  """
  def commit_hash do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> {:ok, String.trim(hash)}
      {error, _} -> {:error, error}
    end
  end

  @doc """
  Returns the short git commit hash.
  """
  def short_commit_hash do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> {:ok, String.trim(hash)}
      {error, _} -> {:error, error}
    end
  end

  @doc """
  Returns the current git branch name.
  """
  def branch_name do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {error, _} -> {:error, error}
    end
  end

  @doc """
  Returns git status information.
  """
  def status do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> {:ok, :clean}
      {output, 0} when output != "" -> {:ok, :dirty}
      {error, _} -> {:error, error}
    end
  end

  @doc """
  Returns the current git tag (if any) pointing to HEAD.
  """
  def current_tag do
    case System.cmd("git", ["describe", "--exact-match", "--tags", "HEAD"],
           stderr_to_stdout: true
         ) do
      {tag, 0} -> {:ok, String.trim(tag)}
      {_error, _} -> {:error, :no_tag}
    end
  end

  @doc """
  Returns the latest git tag in the repository.
  """
  def latest_tag do
    case System.cmd("git", ["describe", "--tags", "--abbrev=0"], stderr_to_stdout: true) do
      {tag, 0} -> {:ok, String.trim(tag)}
      {error, _} -> {:error, error}
    end
  end

  @doc """
  Returns all git tags in the repository.
  """
  def all_tags do
    case System.cmd("git", ["tag", "-l"], stderr_to_stdout: true) do
      {tags, 0} ->
        tag_list =
          tags
          |> String.trim()
          |> String.split("\n", trim: true)

        {:ok, tag_list}

      {error, _} ->
        {:error, error}
    end
  end

  @doc """
  Returns comprehensive git information.
  """
  def info do
    %{
      commit_hash: commit_hash(),
      short_commit_hash: short_commit_hash(),
      branch: branch_name(),
      status: status(),
      current_tag: current_tag(),
      latest_tag: latest_tag(),
      all_tags: all_tags(),
      version: Application.spec(:ex_zstd_zig, :vsn) |> to_string()
    }
  end

  @doc """
  Returns a formatted version string with git information.
  """
  def version_string do
    info_map = info()

    case info_map do
      %{
        version: version,
        short_commit_hash: {:ok, hash},
        branch: {:ok, branch},
        status: {:ok, status},
        current_tag: current_tag
      } ->
        status_suffix = if status == :dirty, do: "-dirty", else: ""

        case current_tag do
          {:ok, tag} -> "#{version} (#{tag}#{status_suffix})"
          {:error, :no_tag} -> "#{version} (#{branch}@#{hash}#{status_suffix})"
        end

      %{version: version} ->
        version
    end
  end
end
