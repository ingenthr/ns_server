#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
exec erl -pa `find . -type d -name ebin` -boot start_sasl -setcookie nocookie -eval 'application:start(ns_server).' $1 $2 $3 $4 $5 $6 $7 $8 $9