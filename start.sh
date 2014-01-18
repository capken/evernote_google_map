#!/bin/bash

cd /home/allen/codes/evernote_google_map/
git pull

thin -s 3 -C ./deploy/thin.yml start
sudo /etc/init.d/lighttpd start -f deploy/lighttpd.conf
