#!/bin/bash

cd /home/allen/codes/evernote_google_map/
unicorn -c deploy/unicorn.rb -D
sudo cp deploy/nginx.conf /etc/nginx/nginx.conf
sudo /etc/init.d/nginx start
