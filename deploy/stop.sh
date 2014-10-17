#!/bin/bash

cd /home/allen/codes/evernote_google_map/
cat ./tmp/pids/unicorn.pid | xargs kill -QUIT
sudo /etc/init.d/nginx stop
