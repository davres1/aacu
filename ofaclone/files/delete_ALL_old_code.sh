#!/bin/ksh
#set -x
####################################################################################
# Script:       delete_ALL_old_code.sh
# Version:      2.0.7, February 11, 2021
# Note:         This script will delete all existing application tier files
#
# Script History:
# Aug 16, 2016 a35321 - initial draft
# Sep 20, 2020 Tom M - v2.0.2: Updates for new EBS 12.2.9:
# 				Prompt user for FS1 or FS2
# 				Add FMW_HOME and Inst to be deleted
# Oct 07, 2020 Tom M - v2.0.3: Remove Prompt for FS1/FS2. Everything under FS1/FS2
#                              will be deleted as standard.
# Oct 23, 2020 Tom M - v2.0.4: Recreate the necessary MINIMUM directories needed
# Nov 02, 2020 Tom M - v2.0.5: Add CHOWN and CHMOD for new directories
# Jan 15, 2021 Tom M - v2.0.6: Moved CHOWN and CHMOD to start at FS1 and FS1
# Feb 11, 2021 Tom M - v2.0.7: Added rm of /u02/oracle/${INSTANCE}/fs_ne directory
####################################################################################

##############################################
# Get the instance name
##############################################

if [ $# -ne 1 ]
then

   echo "\n\n\n"
   echo "*************************************************************************"
   echo "USAGE ERROR for $0, You must pass an instance name"
   echo ""
   echo "eg, $0 edba "
   echo "*************************************************************************"
   echo "$0 exiting.\n\n\n"
   exit 1

fi

INSTANCE=$1

# echo ""
# echo ""
# echo "##########################################################################"
# echo "  WARNING! "
# echo "   You are about to DELETE everything under the following EBS Directories:"
# echo "         /u02/oracle/${INSTANCE}/fs1"
# echo "         /u02/oracle/${INSTANCE}/fs2"
# echo "         /u02/oracle/${INSTANCE}/fs_ne"
# echo ""
# echo "##########################################################################"
# echo ""
# echo "Verify this is correct and type \"yes\" to "
# echo "continue (anything else to abort): \c"
# echo ""
# read Continue
# if [[ ${Continue} != "yes" ]]
# then
#         echo "\n\n"
#         echo "*************************************************************************"
# 	echo "  Script Aborted! EBS Directories Have NOT Been Removed!"
#         echo "*************************************************************************"
#         echo "\n\n"
# 	exit
# fi

echo ""
echo ""
echo "*******************************************************************"
echo "`date`...START resetting FS1/FS2/FS_NE code directories..."
echo "`date`.... Removing /u02/oracle/${INSTANCE}/fs1 directory contents"
rm -rf /u02/oracle/${INSTANCE}/fs1/* &

echo "`date`.... Removing /u02/oracle/${INSTANCE}/fs2 directory contents"
rm -rf /u02/oracle/${INSTANCE}/fs2/* &

echo "`date`.... Deleting /u02/oracle/${INSTANCE}/fs_ne directory and contents"
rm -rf /u02/oracle/${INSTANCE}/fs_ne/ &

wait

echo "`date`.... Contents of /u02/oracle/${INSTANCE} directory:"
ls -ltr /u02/oracle/${INSTANCE}

echo "`date`.... Contents of /u02/oracle/${INSTANCE}/fs1 directory:"
ls -ltr /u02/oracle/${INSTANCE}/fs1

echo "`date`.... Contents of /u02/oracle/${INSTANCE}/fs2 directory:"
ls -ltr /u02/oracle/${INSTANCE}/fs2

echo "...VERIFY FS1 and FS2 are empty before proceeding..."
echo "...VERIFY FS_NE does NOT exist before proceeding..."
echo ""
echo "`date`...DONE resetting  FS1/FS2/FS_NE code directories..."
echo "*******************************************************************"

echo "*******************************************************************"
echo "`date`...START creating new minimum directories..."
echo "... Creating /u02/oracle/${INSTANCE}/fs1/EBSapps directory:"
mkdir -p /u02/oracle/${INSTANCE}/fs1/EBSapps

echo "... Creating /u02/oracle/${INSTANCE}/fs2/EBSapps directory:"
mkdir -p /u02/oracle/${INSTANCE}/fs2/EBSapps

echo "`date`...DONE creating new minimum directories..."
echo "*******************************************************************"
echo " "
echo "*******************************************************************"
echo "`date`...START setting ownership/permissions on FS1 and FS2..."
echo "... Setting /u02/oracle/${INSTANCE}/fs1 to applmgr:dba and 777"
chown -R applmgr:dba /u02/oracle/${INSTANCE}/fs1
chmod -R 0777 /u02/oracle/${INSTANCE}/fs1

echo " "
echo "... Setting /u02/oracle/${INSTANCE}/fs2 to applmgr:dba and 777"
chown -R applmgr:dba /u02/oracle/${INSTANCE}/fs2
chmod -R 0777 /u02/oracle/${INSTANCE}/fs2
echo "*******************************************************************"
echo "`date`...DONE setting ownership/permissions on FS1 and FS2..."

echo " "
echo "*******************************************************************"
echo "... Checking Directories Under FS1...."
ls -ltra  /u02/oracle/${INSTANCE}/fs1 | sort
echo ""
echo "... Checking Directories Under FS2...."
ls -ltra  /u02/oracle/${INSTANCE}/fs2 | sort

echo " "
echo "...DO NOT CONTINUE IF: "
echo "     - No Directories are listed under FS1 or FS2"
echo "     - Directories listed are NOT set to applmgr:dba and 777"
echo "*******************************************************************"
echo ""

