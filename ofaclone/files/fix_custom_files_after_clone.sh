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

INSTANCE_NAME=$1
export INSTANCE_NAME

. /var/opt/oracle/oravmmc $INSTANCE_NAME


#########################################
# Start by Backing up the Orig form files
#########################################
cd /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US
cp XBO_FNDCPMCP.fmx XBO_FNDCPMCP.fmx_$$
cp XBO_FNDCPMPE.fmx XBO_FNDCPMPE.fmx_$$
cp XBO_FNDCPMPE_RO.fmx XBO_FNDCPMPE_RO.fmx_$$
cp XBO_FNDCPVCM_RO.fmx XBO_FNDCPVCM_RO.fmx_$$
cp XBO_FNDFMFUN_RO.fmx XBO_FNDFMFUN_RO.fmx_$$
cp XBO_FNDMNMNU.fmx XBO_FNDMNMNU.fmx_$$
cp XBO_FNDRSGRP.fmx XBO_FNDRSGRP.fmx_$$
cp XBO_FNDSCAUS.fmx XBO_FNDSCAUS.fmx_$$
cp XBO_FNDSCRSP.fmx XBO_FNDSCRSP.fmx_$$


#############################################
# Remove old symbolic links to resource files
#############################################
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDCPMCP.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDCPMPE.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDCPMPE_RO.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDCPVCM_RO.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDFMFUN_RO.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDMNMNU.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDRSGRP.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDSCAUS.fmb
rm /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/XBO_FNDSCRSP.fmb

#########################################
# Create Symbolic links to resource files
#########################################
cd /u01/$INSTANCE_NAME/applmgr/appl/au/11.5.0/forms/US/
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDCPMCP.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDCPMPE.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDCPMPE_RO.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDCPVCM_RO.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDFMFUN_RO.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDMNMNU.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDRSGRP.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDSCAUS.fmb ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/resource/XBO_FNDSCRSP.fmb ./
 
######################################
# Regenerate the form files
# While still under $AU_TOP/forms/US
######################################
f60gen userid=apps/sppa0521 module=XBO_FNDCPMCP.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDCPMCP.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDCPMPE.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDCPMPE.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDCPMPE_RO.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDCPMPE_RO.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDCPVCM_RO.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDCPVCM_RO.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDFMFUN_RO.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDFMFUN_RO.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDMNMNU.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDMNMNU.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDRSGRP.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDRSGRP.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDSCAUS.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDSCAUS.fmx module_type=form batch=no compile_all=special

f60gen userid=apps/sppa0521 module=XBO_FNDSCRSP.fmb output_file=/u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/forms/US/XBO_FNDSCRSP.fmx module_type=form batch=no compile_all=special


#################################
# Regenerate links for bin files
#################################
cd /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/bin/
rm /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/bin/test
rm /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/bin/VMMCBKFD
rm /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/bin/VMMCEEIN
rm /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/bin/VMMCEMPI
rm /u01/$INSTANCE_NAME/applmgr/custom/xbol/11.5.0/bin/vmmcghxnuviaitemload

ln -s /u01/$INSTANCE_NAME/applmgr/appl/fnd/11.5.0/bin/fndcpesr ./test
ln -s /u01/$INSTANCE_NAME/applmgr/appl/fnd/11.5.0/bin/fndcpesr ./VMMCBKFD
ln -s /u01/$INSTANCE_NAME/applmgr/appl/fnd/11.5.0/bin/fndcpesr ./VMMCEEIN
ln -s /u01/$INSTANCE_NAME/applmgr/appl/fnd/11.5.0/bin/fndcpesr ./VMMCEMPI
ln -s /u01/$INSTANCE_NAME/applmgr/appl/fnd/11.5.0/bin/fndcpesr ./vmmcghxnuviaitemload


##########################################
# Create links in APPL_TOP to custom files
##########################################
cd /u01/$INSTANCE_NAME/applmgr/appl
rm xbol
rm kbace
ln -s /u01/$INSTANCE_NAME/applmgr/custom/xbol ./
ln -s /u01/$INSTANCE_NAME/applmgr/custom/kbace ./


##############
# Exit here
##############
exit 0;
