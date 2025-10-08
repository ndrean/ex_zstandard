defmodule ExZstdZig.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_zstd_zig,
      version: version(),
      elixir: "~> 1.18",
      name: "ExZstdZig",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  defp version do
    base_version = "0.1.0"

    case System.cmd("git", ["describe", "--always", "--dirty"], stderr_to_stdout: true) do
      {git_info, 0} ->
        git_info = String.trim(git_info)

        if String.contains?(git_info, "dirty") do
          "#{base_version}-#{git_info}"
        else
          case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
            {commit_hash, 0} -> "#{base_version}+#{String.trim(commit_hash)}"
            _ -> base_version
          end
        end

      _ ->
        base_version
    end
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zigler, git: "https://github.com/E-xyza/zigler/", tag: "0.15.1", runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :docs], runtime: false}
    ]
  end

  defp docs do
    [
      main: "ExZstdZig",
      source_url: "https://github.com/ndrean/ex_zstd_zig",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      description: "Fast Zstandard compression/decompression for Elixir using Zig NIFs",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/ndrean/ex_zstd_zig",
        "Zstandard" => "https://facebook.github.io/zstd/"
      },
      name: :ex_zstd_zig,
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
