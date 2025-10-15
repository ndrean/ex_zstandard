defmodule ExZstandard.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_zstandard,
      version: "0.1.0",
      elixir: "~> 1.18",
      name: "ExZstandard",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      dialyzer: dialyzer()
    ]
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
      {:req, "~> 0.5.15"},
      {:zigler, git: "https://github.com/E-xyza/zigler/", tag: "0.15.1", runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :docs], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "ExZstandard",
      source_url: "https://github.com/ndrean/ex_zstandard",
      extras: ["README.md"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit, :logger, :req],
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp package do
    [
      description: "Fast Zstandard compression/decompression for Elixir using Zig NIFs",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/ndrean/ex_zstandard",
        "Zstandard" => "https://facebook.github.io/zstd/"
      },
      name: :ex_zstandard,
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
