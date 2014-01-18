#!/bin/bash

cd /home/allen/codes/evernote_google_map/

ls tmp/pids/thin*pid | xargs -I PID thin -P PID stop

sudo /etc/init.d/lighttpd stop -f deploy/lighttpd.conf
