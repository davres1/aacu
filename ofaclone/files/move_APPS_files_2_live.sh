#!/bin/ksh
#set -x
####################################################################################
# Script:       move_APPS_files_2_live.sh
# Version:      V 2.0.2 Sep 20, 2020
# Note:         This script will move production files into place locally
#
# Script History:
# Aug 16, 2016 a35321 - initial draft
# Sep 20, 2020 - Tom M - v2.0.2: Updates for new EBS 12.2.9:
#                                 Prompt user for FS1 or FS2
# 				  Add logic to check if RUN_BASE is Set and allow the
#                                 user to exit the script if it is not
####################################################################################

##############################################
# Get the instance name
##############################################

if [ $# -ne 2 ]
then

   echo "\n\n\n"
   echo "*************************************************************************"
   echo "USAGE ERROR for $0"
   echo "You must pass an instance name"
   echo "eg, $0 edba "
   echo "*************************************************************************"
   echo "$0 exiting.\n\n\n"
   exit 1

fi

INSTANCE=$1
FSRunBase=$2

# echo "\n\n\n"
# echo "####################################################################"
# echo "# Select the FS Run_Base Location to Move Clone Directories To"
# echo "####################################################################"
# echo ""
# echo "Please enter \"fs1\" or \"fs2\" as the RUN_BASE Location to move the new"
# echo "EBS directories to (anything else to abort): \c"
# read FSRunBase
# if [[ ${FSRunBase} != "fs1" && ${FSRunBase} != "fs2" ]]
# then
#     echo "\n\n"
#     echo "*************************************************************************"
#     echo "  Script Aborted! The value fs1 or fs2 was not supplied ! Rerun Script"
#     echo "*************************************************************************"
#     echo "\n\n"
#     exit
# fi

export RUN_BASE=/u02/oracle/${INSTANCE}/${FSRunBase}

###
## Verify that the RUN_BASE value is correctly set
## If it is not then the script can be exited to 
## avoid the APPL directories being moved to the root filesystem
###
# echo "\n\n"
# echo "####################################################################"
# echo "You are about to MOVE THE APPS DIRECTORIES to EBSapps."
# echo "The RUN_BASE variable needs to be set to the correct FS"
# echo "location for this to happen. The current value is: "
# echo "    "
# echo "   RUN_BASE Value:  ${RUN_BASE}"
# echo ""
# echo "####################################################################"
# echo ""
# echo "Verify This is the Correct Value and type \"yes\" to "
# echo "continue with the move (anything else to abort): \c"
# echo ""
# read Continue
# if [[ ${Continue} != "yes" ]]
# then
#     echo "\n\n"
#     echo "*************************************************************************"
#     echo "  SCRIPT ABORTED! APPS Directories Have NOT Been Moved!"
#     echo "*************************************************************************"
#     echo "\n\n"
#     exit
# fi


## Use the RUN_BASE variable
echo ""
echo "`date`...START moving New APPLMGR code directories..."
echo "`date`....Moving EBSapps 10.1.2 code directory"
mv /clone_tar_files/10.1.2 $RUN_BASE/EBSapps

echo ""
echo "`date`....Moving EBSapps comn code directory"
mv /clone_tar_files/comn $RUN_BASE/EBSapps

## Need to delete the appl directory that only has the ENV file in it
## before we can use the MV command
echo ""
echo "`date`....Deleting EBSapps appl code directory with ENV file"
rm -fr $RUN_BASE/EBSapps/appl
echo "`date`....Moving EBSapps appl code directory"
mv /clone_tar_files/appl $RUN_BASE/EBSapps

