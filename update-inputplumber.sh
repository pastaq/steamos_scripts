#!/bin/bash
sudo systemctl stop inputplumber.service
if [[ -f inputplumber-x86_64.tar.gz ]]; then
  rm -rf inputplumber
  tar xvfz inputplumber-x86_64.tar.gz && rm inputplumber-x86_64.tar.gz
  sudo cp -r inputplumber/usr /
fi
if [[ -f .inputplumber.log ]]; then
  mv .inputplumber.log .inputplumber.log.old
fi
sudo systemctl daemon-reload
case $1 in
trace)
  sudo LOG_LEVEL=trace inputplumber 2>&1 | tee .inputplumber.log
  ;;
none)
  ;;
monitor)
  sudo LOG_LEVEL=debug ENABLE_METRICS=1 inputplumber | tee .inputplumber.log
  ;;
no-log)
  sudo LOG_LEVEL=debug inputplumber
  ;;
*)
  sudo LOG_LEVEL=debug inputplumber 2>&1 | tee .inputplumber.log
  ;;
esac
