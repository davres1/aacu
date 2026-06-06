#!/usr/bin/ksh
####################################################################################
# $Id:  change_apps_passwd.sh | ver: 1.2.0 | Feb 14, 2017  $
# Script:  change_apps_passwd.sh
#
# Purpose:  This script will change the application owner (apps) database
#           password. It requires the name of the database , DB system password, apps
#	    password, and will also verify that concurrent managers are not running.
#
# Script History:
# Aug 19, 2016  a35321 create script for general pw change script
# Feb 14, 2017	Jeff Z Modify to perform global password change
####################################################################################
# Verify User name
#####################

WHOM=`/usr/bin/whoami`
if [ "$WHOM" != "applmgr" ]
then

    echo "********************************************"
    echo "You must be APPLMGR to execute this script..."
    echo "********************************************"
    exit 0

fi


########################################################
# Check to see that INSTANCE is passed as a parameter
########################################################

if [ $# != 4 ] ;  then

   echo "\n\n\n"
   echo "************************************************************"
   echo "USAGE ERROR for $0"
   echo "You must pass an ORACLE DB Instance name, DB SYSTEM PW "
   echo "old APPS PW, and the new APPS PW "
   echo "\n "
   echo "eg, $0 edba <SYSTEM_PW> <OLD_APPS_PW> <NEW_APPS_PW> "
   echo "************************************************************"
   echo "$0 exiting.\n\n\n"
   exit 1;
fi

typeset -l INSTANCE=$1
typeset -u SYSTEM_PW=$2
typeset -u OLD_APPS_PW=$3
typeset -u NEW_APPS_PW=$4


########################################################
# Set up environment for the instance
########################################################
. /usr/vmmc/bin/oracle_scripts/oravmmc $INSTANCE


#####################################################################
# Make sure that the concurrent managers are not running first
#####################################################################
echo ""
echo "Now Verifying that the Concurrent Managers are NOT running..."

CHECK_PROC="FNDSM"
VERIFY=`ps -ef|grep $CHECK_PROC|grep -v grep`

if [ "$VERIFY" != "" ]
then
   echo "ERROR...Please shutdown Concurrent Managers before running this script..."
   exit 1;
else
   echo "OK...Concurrent Managers are not running...continuing."
fi


#############################
# Now change the apps passwd
#############################

### Change module password 
FNDCPASS apps/${OLD_APPS_PW} 0 Y system/${SYSTEM_PW} ALLORACLE ${NEW_APPS_PW}

### Change applsyspub password 
FNDCPASS apps/${OLD_APPS_PW} 0 Y system/${SYSTEM_PW} ORACLE APPLSYSPUB ${NEW_APPS_PW}

### Change apps applsys password 
FNDCPASS apps/${OLD_APPS_PW} 0 Y system/${SYSTEM_PW} SYSTEM APPLSYS ${NEW_APPS_PW}

sqlplus "apps/${APPS_PW}@${INSTANCE}" << FROM_HERE
show user
exit
FROM_HERE
