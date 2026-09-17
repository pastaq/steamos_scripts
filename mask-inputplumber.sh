#!/bin/bash

case $1 in
disable)
  sudo systemctl unmask inputplumber && sudo systemctl start inputplumber.service 
  echo "InputPlumber masking disabled."
  ;;
enable)
  sudo systemctl mask inputplumber && sudo systemctl stop inputplumber.service 
  echo "InputPlumber masking enabled."
  ;;
*)
  echo "Invalid option: {$1}, use enable or disable"
  exit -1
  ;;
esac
systemctl status inputplumber

