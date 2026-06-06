#!/bin/bash
#. /home/`whoami`/.bash_profile
#. /home/prodapp/APPSPRODORA_ebsapp.env
PATCHLIST=$1
FORCE=$2
#STAGE=$3
STAGE=/stage/R12_patches
OPTIONS=hotpatch,prereq
OPTIONS="${3:=hotpatch}"
#MAIN=$5
HOST=`hostname -a`
echo $HOST
if [ $# -gt 2 ]
        then
                echo ""
#                echo "STOPPING --- usage $0 <instance name PRODORA,R12STG,R12DEV,R12TEST> <patch list file comman separated> <Staging location > <Patch options i.e. hotpatch> "
                echo "STOPPING --- usage $0 <patch list file comman separated> <f to ally forefully>"
                echo ""
                exit 1
fi
#if [ $4 = 'Y' -o $4 = "y"  ]
#        then
#                echo "Enabling maintenance mode"
#                sqlplus apps/$PSWD @$AD_TOP/patch/115/sql/adsetmmd.sql ENABLE
#                echo ""
#fi

if [[ -z $FORCE ]]
then
   FORCE='NOTFORCE'
   echo $FORCE
fi

efile=$HOME/"APPS$TWO_TASK"_"`hostname|awk -F. '{print $1}'`.env"
echo $efile
echo $STAGE
echo $OPTIONS
. $efile


echo `echo $PATCHLIST|sed -n 1'p' | tr ',' '\n'`
echo "Do you want to continue (Y/N)?"
read name
if [ $name = "y" -o $name = "Y" ] ; then
       echo "Good,continuing..."
else
      echo "exiting..."
      exit 1;
fi
for PATCH in `echo $PATCHLIST|sed -n 1'p' | tr ',' '\n'`
do
pout=$(sqlplus -s apps/$PSWD@$TWO_TASK << EOF
    set pagesize 0 feedback off verify off heading off echo off;
    set echo off;
    set head off;
    set feedback off;
    select 1
        from ad_applied_patches aap,
        ad_patch_drivers apd,
        ad_patch_runs apr,
        ad_appl_tops aat
        where aap.applied_patch_id = apd.applied_patch_id
        and apd.patch_driver_id = apr.patch_driver_id
        and aat.appl_top_id = apr.appl_top_id
        and aap.patch_name = '$PATCH' and aat.name = '$HOST';
    exit;
EOF
)

if [ $FORCE == 'f' ]
 then
  echo "Appling $PATCH forcefully" 
elif [ $pout == 1 ]
then 
  echo "$PATCH is already applied. Moving to next Patch...."
  sleep 5
  continue
fi 
    
    
    mv $PATCH $STAGE/Junk_$PATCH
    if [ -d $STAGE/$PATCH ]
    then
    echo "Patch already unzipped"
    else
    echo "Unzipping $PATCH ....."
    rm -rf $STAGE/$PATCH
    unzip $STAGE/p$PATCH*.zip -d $STAGE
     if [ `echo $? == 9 ` ]
     then
       jar -xvf $STAGE/p$PATCH*.zip
     fi
    fi
    if [ -f $APPL_TOP/admin/$TWO_TASK/patch.txt ]
    then
    echo "defaultsfile $APPL_TOP/admin/$TWO_TASK/patch.txt File exists. appling patch ..."
    else
    echo "$APPL_TOP/admin/$TWO_TASK/patch.txt is MISSING"
    fi
adpatch options=$OPTIONS defaultsfile=$APPL_TOP/admin/$TWO_TASK/patch.txt logfile=$PATCH.log workers=24 patchtop=$STAGE/$PATCH driver=u$PATCH.drv
  grep -i FAILED $APPL_TOP/admin/$TWO_TASK/log/$PATCH.log >/tmp/patchtmp.log
  if [ `grep FAILED /tmp/patchtmp.log | wc -l` -ne 0 ]
  then
    echo "Patch $PATCH failed"
    cat $APPL_TOP/admin/$TWO_TASK/log/$PATCH.log |mailx -s "Patch $PATCH failed on `hostname` instance $TWO_TASK" sdavre@cloudsmartservice.com
    rm /tmp/patchtmp.log
    rm -rf $STAGE/$PATCH
    exit 1
  else
    tail -10 $APPL_TOP/admin/$TWO_TASK/log/$PATCH.log |mailx -s "$PATCH applied on `hostname` instance $TWO_TASK" sdavre@cloudsmartservice.com
    rm /tmp/patchtmp.log
    rm -rf $STAGE/$PATCH
  fi
done

#echo "Disabling maintenance mode"
#               sqlplus apps/$PSWD @$AD_TOP/patch/115/sql/adsetmmd.sql DISABLE
#
#exit


