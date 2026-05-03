#!/bin/bash

# Build the Elixir project
echo "Building Elixir project..."
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build

# Start Symphony on port 8089
echo "Starting Symphony on port 8089..."
mise exec -- ./bin/symphony ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 8089
