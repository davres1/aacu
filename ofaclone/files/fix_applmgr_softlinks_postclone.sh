#!/bin/ksh
##################################################################
# Script:  fix_applmgr_softlinks_postclone.sh 
# Dated:   Oct 12, 2012
# Author:  Jeff Zhang, VMMC
#
# Notes:
# This script will remove the old source symbolic links and
# recreate them to point to the correct ORACLE_SID path during the
# cloning process.
#
# Script History:
# 10/12/2012 - JZhang:  Created new script for R12.
# 09/20/2020 - Tmoloney: Updated to support 12.2.9 RUN_BASE
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
   echo "You must pass an EBS database environment name "
   echo "************************************************************"
   echo "$0 exiting.\n\n\n"
   exit 1

fi

INSTANCE=$1
export INSTANCE

typeset -l NODE=`uname -n`
export NODE

. /usr/vmmc/bin/oracle_scripts/oravmmc $INSTANCE

#####
## Source the EBSapps.env for the RUN environment
## This ensures the files from the correct FS1 or F2 path are copied
####
echo ""
. /u02/oracle/${INSTANCE}/EBSapps.env run


###
## Create the softlinks
###
echo "`date` - Creating softlinks"

##echo "${RUN_BASE}/EBSapps/appl/xbol/12.0.0/sql/"
##ln -sf ${RUN_BASE}/EBSapps/appl/xbol/12.0.0/sql/ ${RUN_BASE}/EBSapps/appl/xbol/12.0.0/sql/US

echo "${RUN_BASE}/EBSapps/10.1.2/nls/lbuilder/lbuilder"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/nls/lbuilder/lbuilder ${RUN_BASE}/EBSapps/10.1.2/bin/lbuilder

echo "${RUN_BASE}/EBSapps/10.1.2/webcache/bin/webcachectl"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/webcache/bin/webcachectl ${RUN_BASE}/EBSapps/10.1.2/bin/webcachectl

echo "${RUN_BASE}/EBSapps/10.1.2/lib32/hsdb_odbc.so"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/lib32/hsdb_odbc.so ${RUN_BASE}/EBSapps/10.1.2/lib/hsdb_odbc.so

echo "${RUN_BASE}/EBSapps/10.1.2/lib32/hsdb_ora.so"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/lib32/hsdb_ora.so ${RUN_BASE}/EBSapps/10.1.2/lib/hsdb_ora.so

echo "${RUN_BASE}/EBSapps/10.1.2/lib32/hsdb_syb.so"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/lib32/hsdb_syb.so ${RUN_BASE}/EBSapps/10.1.2/lib/hsdb_syb.so

echo "${RUN_BASE}/EBSapps/10.1.2/lib32/libnavhoa.a"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/lib32/libnavhoa.a ${RUN_BASE}/EBSapps/10.1.2/lib/libnavhoa.a

echo "${RUN_BASE}/EBSapps/10.1.2/precomp/public32/bnddsc.for"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/bnddsc.for ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/BNDDSC.FOR

echo "${RUN_BASE}/EBSapps/10.1.2/precomp/public32/oraca.for"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/oraca.for ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/ORACA.FOR

echo "${RUN_BASE}/EBSapps/10.1.2/precomp/public32/seldsc.for"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/seldsc.for ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/SELDSC.FOR

echo "${RUN_BASE}/EBSapps/10.1.2/precomp/public32/sqlca.for"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/sqlca.for ${RUN_BASE}/EBSapps/10.1.2/precomp/public32/SQLCA.FOR

echo "${RUN_BASE}/EBSapps/10.1.2/sysman/jlib/log4j-core.jar"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/sysman/jlib/log4j-core.jar ${RUN_BASE}/EBSapps/10.1.2/sysman/webapps/emd/WEB-INF/lib/log4j-core.jar

echo "${RUN_BASE}/EBSapps/10.1.2/webcache/docs/readme.examples.html"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/webcache/docs/readme.examples.html ${RUN_BASE}/EBSapps/10.1.2/webcache/examples/readme.examples.html

echo "${RUN_BASE}/EBSapps/10.1.2/lib/ldflags"
ln -sf ${RUN_BASE}/EBSapps/10.1.2/lib/ldflags ${RUN_BASE}/EBSapps/10.1.2/lib32/ldflags



###############################################
# Now fix the custom forms executable & relink
###############################################

echo "`date` - Create ldflags symbolic links...."
cd $ORACLE_HOME/lib32
rm ldflags
ln -s $ORACLE_HOME/lib/ldflags $ORACLE_HOME/lib32/

echo "`date` - Now compiling apps forms executable..."
cd $ORACLE_HOME/forms/lib32/
make -f ins_forms.mk install

echo ""
echo ""
echo ""
echo ""
echo ""
echo "***********************************************************************************"
echo "PLEASE NOTE:  That LD errors during the remake is NORMAL and can safely be IGNORED!"
echo "***********************************************************************************"
echo ""
echo ""
echo ""
