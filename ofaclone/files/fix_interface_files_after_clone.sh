##################################################################
# Script:  fix_interface_files_after_clone.sh
# Dated:   July 10. 2009
# Author:  Wendy S. Nygren, VMMC
#
# Notes:
# This script will clear the /interface directories
#
# Script History:
# 07.10.2009:  spgwsn - created new script.
##################################################################

# ####################
# Verify User name
# ####################

WHOM=`/usr/bin/whoami`
if [ "$WHOM" != "root" ]
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

##############
# Exit here
##############
exit 0;
