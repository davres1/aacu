##################################################################
# Script:  fix_custom_files_after_clone.sh
# Dated:   March 12, 2007
# Author:  Wendy S. Nygren, VMMC
#
# Notes:
# This script will generate new form files for our custom forms.
# The original copies will be saved prior to the compilation.
#
# Script History:
# 03.12.2007:  spgwsn - created new script.
# 10.27.2012:  spgwsn - Modify for R12.
# 04.08.2015:  spgwsn - Modified to clear the two OA_HTML cache
#              directories after a refresh.
# Sep 20, 2020: Tmoloney: Updated to support 12.2.9 RUN_BASE
##################################################################

# ####################
# Verify User name
# ####################

WHOM=`/usr/bin/whoami`
if [ "$WHOM" != "applmgr" ]
then

    echo "********************************************"
    echo "You must be APPLMGR to execute this script..."
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

typeset -l NODE=`uname -n`
export NODE

. /usr/vmmc/bin/oracle_scripts/oravmmc $INSTANCE

###
## Source the EBSApps.env file to ensure RUN_BASE Gets Set Correctly
###
. /u02/oracle/${INSTANCE}/EBSapps.env RUN


####################
# Create Misc Links
####################
ln -s $VMDIR/start_all_applmgr_$INSTANCE.sh  ${RUN_BASE}/inst/apps/$INSTANCE\_$NODE/admin/scripts
ln -s $VMDIR/stop_all_applmgr_$INSTANCE.sh   ${RUN_BASE}/inst/apps/$INSTANCE\_$NODE/admin/scripts
ln -s $VMDIR/disable_maint_mode_$INSTANCE.sh ${RUN_BASE}/inst/apps/$INSTANCE\_$NODE/admin/scripts
ln -s $VMDIR/enable_maint_mode_$INSTANCE.sh  ${RUN_BASE}/inst/apps/$INSTANCE\_$NODE/admin/scripts

########################
# Open File Permissions
########################
chmod -R 777 $JAVA_TOP/xxvmmc
chmod -R 777 $COMMON_TOP/temp
chmod -R 777 $COMMON_TOP/admin/out*
chmod -R 777 $COMMON_TOP/admin/log
chmod -R 777 $PO_TOP/forms
rm $XBOL_TOP/sql/US
chmod -R 777 $XBOL_TOP
ln -s $XBOL_TOP/sql/ $XBOL_TOP/sql/US
chmod 755 $ORACLE_HOME/bin/sqlplus

echo ""
echo ""
echo "Now clearing OA_HTML cache directories"
rm $OA_HTML/cabo/images/cache/*
rm $OA_HTML/cabo/styles/cache/*

echo ""
echo "Now Clearing Old EBS Web and Diagnostic Logs..."
rm -rf $IAS_ORACLE_HOME/instances/EBS_web_OHS1/diagnostics/logs/*
rm -rf $IAS_ORACLE_HOME/instances/EBS_web_eprod_OHS1/diagnostics/logs/*


##############
# Exit here
##############
exit 0;
