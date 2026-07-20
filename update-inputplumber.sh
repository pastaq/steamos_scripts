#!/bin/bash
sudo systemctl stop inputplumber.service
rm -rf inputplumber
tar xvfz inputplumber-x86_64.tar.gz && rm inputplumber-x86_64.tar.gz
sudo cp -r inputplumber/usr /
mv .inputplumber.log .inputplumber.log.old
#sudo systemctl daemon-reload
case $1 in
(trace)
  sudo LOG_LEVEL=trace inputplumber 2>&1 | tee .inputplumber.log
  ;;
(none)
  ;;
(no-log)
  sudo LOG_LEVEL=debug inputplumber 
  ;;
*)
  sudo LOG_LEVEL=debug inputplumber 2>&1 | tee .inputplumber.log
esac
