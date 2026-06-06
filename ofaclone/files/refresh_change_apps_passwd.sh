#!/usr/bin/ksh
####################################################################################
# $Id:  refresh_change_apps_passwd.sh | ver: 1.1.0 | Aug 19, 2016  $
# Script:  refresh_change_apps_passwd.sh
#
# Purpose:  This script will change the application owner (apps) database
#           password post DB refresh.  This is needed for when an environment gets refreshed.
#           If requires the name of the database and will also verify that
#           the concurrent managers are not running.
#
# Script History:
# Aug 19, 2016  a35321 create script for post refresh change pw script
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

if [ $# != 3 ] ;  then

   echo "\n\n\n"
   echo "************************************************************"
   echo "USAGE ERROR for $0"
   echo "You must pass an ORACLE Instance name, DB system passowrd "
   echo "and the new apps password "
   echo "\n "
   echo "eg, $0 edba <SYSTEM_PW> <NEW_NONPROD_APPS_PW> "
   echo "************************************************************"
   echo "$0 exiting.\n\n\n"
   exit 1;
fi

typeset -l INSTANCE=$1
typeset -u SYSTEM_PW=$2
typeset -u APPS_PW=$3


########################################################
# Set up environment for the instance
########################################################
. /usr/vmmc/bin/oracle_scripts/oravmmc $INSTANCE

######################################
# Check env against master config file
######################################
PRODINSTANCE=eprod
TABchar="	"        #This is a TAB character for use here and there
ERPcfgfile=/usr/vmmc/bin/root_scripts/MasterERPAppConfiguration.tab

ERPcfg_exist=`grep "_${PRODINSTANCE}${TABchar}" ${ERPcfgfile} | wc -l`

if [ ${ERPcfg_exist} -lt 7 ]
then
   echo ""
   echo "WARNING: the ${PRODINSTANCE} environment is not in the Master App Config File"
   echo ""
   exit 1
fi

PROD_PW=`grep "T_APPPW_${PRODINSTANCE}${TABchar}"   ${ERPcfgfile} | cut -f2`


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

FNDCPASS apps/${PROD_PW} 0 Y system/"${SYSTEM_PW}" SYSTEM APPLSYS ${APPS_PW}

sqlplus "apps/${APPS_PW}@${INSTANCE}" << FROM_HERE
show user
exit
FROM_HERE
