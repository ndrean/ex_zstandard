# Start Finch for HTTP streaming tests
{:ok, _} = Finch.start_link(name: MyFinch)

# Exclude network-dependent and experimental tests by default
# Run them with: mix test --include network_dependent
ExUnit.start(exclude: [:network_dependent])
