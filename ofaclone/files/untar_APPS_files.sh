#!/bin/ksh
#set -x
####################################################################################
# Script:       untar_APPS_files.sh
# Version:      2.0.0, September 20, 2020
# Note:         This script will untar the latest APP GTAR files
#
# Script History:
#  September 20, 2020 Tom M - v2.0.0: Updates for new EBS 12.2.9
#
####################################################################################

echo `date` "... Remove old directories"
echo `date` ".... Remove EBSApps 10.1.2 Directory"
rm -rf /clone_tar_files/10.1.2 &

echo `date` ".... Remove EBSApps comn Directory"
rm -rf /clone_tar_files/comn &

echo `date` ".... Remove EBSApps appl Directory"
rm -rf /clone_tar_files/appl &

wait
echo `date` "... Completed removal of old directories"

echo `date` "... Starting unzipping of GTAR files"
echo `date` ".... Unzip EBSApps 10.1.2 Directory"
gtar -xf /clone_tar_files/EBSapps_10_1_2_eprod.gtar --preserve-permissions --same-owner -C, --directory=/clone_tar_files &

echo `date` ".... Unzip EBSApps comn Directory"
gtar -xf /clone_tar_files/EBSapps_comn_eprod.gtar --preserve-permissions --same-owner -C, --directory=/clone_tar_files &

echo `date` ".... Unzip EBSApps appl Directory"
gtar -xf /clone_tar_files/EBSapps_appl_eprod.gtar --preserve-permissions --same-owner -C, --directory=/clone_tar_files &

wait
echo `date` "... Completed unzipping of GTAR files"
