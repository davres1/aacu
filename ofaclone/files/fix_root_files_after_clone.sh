#!/bin/ksh
#set -x
##################################################################
# Script:  fix_interface_files_after_clone.sh
# Dated:   July 10. 2009
# Author:  Wendy S. Nygren, VMMC
#
# Notes:
# This script will clear the /interface directories and open
# file permissions for XBOL_TOP and COMMON_TOP.
#
# Script History:
# 07.10.2009:  spgwsn - created new script.
# 12.02.2016:  a35321 - added explicitly ksh environment setting
# Oct 23, 2020: TMoloney: Updated to support 12.2.9 RUN_BASE
##################################################################

# ####################
# Verify User name
# ####################

WHOM=`/usr/bin/whoami`
if [ "$WHOM" != "oracle" ]
then

    echo "********************************************"
    echo "You must be ROOT to execute this script..."
    echo "********************************************"
    exit 0
fi

# #####################
# Get the instance name
# #####################

if [ $# -ne 1 ]
then

   echo "\n\n\n"
   echo "************************************************************"
   echo "USAGE ERROR for $0"
   echo "You must pass an ORACLE Database name "
   echo "************************************************************"
   echo "$0 exiting.\n\n\n"
   exit 1

fi

INSTANCE=$1
export INSTANCE

###
## Source the EBSApps.env file to ensure RUN_BASE Gets Set Correctly
###
. /u02/oracle/${INSTANCE}/EBSapps.env RUN


######################
# Start Clearing Here
######################

echo ""

if [ -d /interface/infvmmci/$INSTANCE/archive ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/archive..."
   rm -rf /interface/infvmmci/$INSTANCE/archive/*
fi

if [ -d /interface/infvmmci/$INSTANCE/incoming ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/incoming..."
   rm -rf /interface/infvmmci/$INSTANCE/incoming/*
fi

if [ -d /interface/infvmmci/$INSTANCE/outgoing ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/outgoing..."
   rm -rf /interface/infvmmci/$INSTANCE/outgoing/*
fi

if [ -d /interface/infvmmci/$INSTANCE/src ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/src..."
   rm -rf /interface/infvmmci/$INSTANCE/src/*
fi

if [ -d /interface/infvmmci/$INSTANCE/tmp ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/tmp..."
   rm -rf /interface/infvmmci/$INSTANCE/tmp/*
fi

if [ -d /interface/infvmmci/$INSTANCE/bad ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/bad..."
   rm -rf /interface/infvmmci/$INSTANCE/bad/*
fi

if [ -d /interface/infvmmci/$INSTANCE/mobile_warehouse/backup ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/mobile_warehouse/backup..."
   rm -rf /interface/infvmmci/$INSTANCE/mobile_warehouse/backup/*
fi

if [ -d /interface/infvmmci/$INSTANCE/mobile_warehouse ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/mobile_warehouse..."
   rm /interface/infvmmci/$INSTANCE/mobile_warehouse/*
fi

######################
# Start Clearing Here
######################

echo ""

if [ -d /interface/infvmmci/$INSTANCE/archive ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/archive..."
   find /interface/infvmmci/$INSTANCE/archive ! -type d -exec rm -rf '{}' \;
fi

if [ -d /interface/infvmmci/$INSTANCE/incoming ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/incoming..."
   find /interface/infvmmci/$INSTANCE/incoming ! -type d -exec rm -rf'{}' \;
fi

if [ -d /interface/infvmmci/$INSTANCE/outgoing ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/outgoing..."
   find /interface/infvmmci/$INSTANCE/outgoing ! -type d -exec rm -rf '{}' \;
fi

if [ -d /interface/infvmmci/$INSTANCE/src ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/src..."
   find /interface/infvmmci/$INSTANCE/src ! -type d -exec rm -rf '{}' \;
fi

if [ -d /interface/infvmmci/$INSTANCE/tmp ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/tmp..."
   find /interface/infvmmci/$INSTANCE/tmp ! -type d -exec rm -rf '{}' \;
fi

if [ -d /interface/infvmmci/$INSTANCE/bad ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/bad..."
   find /interface/infvmmci/$INSTANCE/bad ! -type d -exec rm -rf '{}' \;
fi


if [ -d /interface/infvmmci/$INSTANCE/mobile_warehouse ]
then
   echo "`date` - Now Clearing /interface/infvmmci/$INSTANCE/mobile_warehouse..."
   find /interface/infvmmci/$INSTANCE/mobile_warehouse ! -type d -exec rm -rf '{}' \;
fi


########################
# Open File Permissions
########################
COMMON_TOP=${RUN_BASE}/EBSapps/comn
chmod -R 777 $COMMON_TOP/temp
chmod -R 777 $COMMON_TOP/admin/out*
chmod -R 777 $COMMON_TOP/admin/log

XBOL_TOP=${RUN_BASE}/EBSapps/appl/xbol/12.0.0
rm $XBOL_TOP/sql/US
chmod -R 777 $XBOL_TOP
ln -s $XBOL_TOP/sql/ $XBOL_TOP/sql/US

##############
# Exit here
##############
exit 0;
