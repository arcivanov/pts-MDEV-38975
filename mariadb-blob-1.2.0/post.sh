#!/bin/sh
# Stop MariaDB server after each test run
cd $HOME/mariadb_
./bin/mariadb-admin -u `basename $DEBUG_REAL_HOME` -pphoronix shutdown 2>/dev/null
sleep 5
