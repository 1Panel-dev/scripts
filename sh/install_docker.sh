#!/bin/bash

country=$(curl -s ipinfo.io/country)
echo "Current server location: $country"

if [[ "$country" == "CN" ]]; then
  bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
else
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
fi
