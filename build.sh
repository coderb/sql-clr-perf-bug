#!/bin/bash
# Builds clr/ClrSpin.dll and writes the scripts in sql/ with it embedded. Needs the .NET SDK, which
# builds a net472 library on Linux, macOS or Windows.
set -euo pipefail
cd "$(dirname "$0")"
dotnet build clr/ClrSpin.csproj -c Release -nologo -v quiet
python3 gen_repro.py
