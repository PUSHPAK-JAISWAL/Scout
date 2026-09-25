#!/usr/bin/env bash
set -e
# One-time (or after updating the webview module):
v ~/.vmodules/ttytm/webview/build.vsh
v -o Scout .
echo "Built ./Scout"
