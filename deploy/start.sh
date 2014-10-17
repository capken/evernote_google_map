#!/bin/bash

cd /home/allen/codes/evernote_google_map/
unicorn -c ./deploy/unicorn.rb -E production -D
sudo /etc/init.d/nginx start
