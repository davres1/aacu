#!/bin/sh
source ~/.profile

Die()
{
    _EXITSTATUS="${?}"
    _BASE=$(basename -- "$0")
    echo -e "${_BASE}: error: $* [exit status ${?}]" >&2
    exit ${_EXITSTATUS}
}


[[ "$#" -eq 6 ]] || Die "Missing input parameters! Usage: $0 <PATCHLIST> <Stage> <Phase> <apps password> <system Password> <Weblogic Password>"

export PATCHLIST=$1
export STAGE=$2
# phase= prepare,apply,finalize,cutover,cleanup or hotpatch
export PHASE="${3:=prepare,apply,finalize,cutover,cleanup}"
export APPSP=$4 
export SYSTEMP=$5 
export WEBLOGICP=$6
#MAIN=$5
HOST=`hostname`
echo $HOST

#if [ $4 = 'Y' -o $4 = "y"  ]
#        then
#                echo "Enabling maintenance mode"
#                sqlplus apps/$PSWD @$AD_TOP/patch/115/sql/adsetmmd.sql ENABLE
#                echo ""
#fi



source {{ app_tgt_mount }}/EBSapps.env RUN


# echo `echo $PATCHLIST|sed -n 1'p' | tr ',' '\n'`
# echo "Do you want to continue (Y/N)?"
# read name
# if [ $name = "y" -o $name = "Y" ] ; then
#        echo "Good,continuing..."
# else
#       echo "exiting..."
#       exit 1;
# fi
for PATCH in `echo $PATCHLIST|sed -n 1'p' | tr ',' '\n'`
do
pout=$(sqlplus -s apps/$PSWD@$TWO_TASK << EOF
    set pagesize 0 feedback off verify off heading off echo off;
    set echo off;
    set head off;
    set feedback off;
    select status from ad_adop_session_patches where bug_number='$PATCH' and node_name in ('edbaapp','$HOST') order by end_date desc;
    exit;
EOF
)

if [ $pout == 'Y' ]
then 
  echo "$PATCH is already applied. Moving to next Patch...."
  sleep 5
  exit 1;
elif  [ $pout == 'R|H|F|C' ]
then
  echo "Other patch is getting applied at ths time...."
  exit 1;
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
done

{ echo $APPSP; echo $SYSTEMP; echo $WEBLOGICP; } | adop phase=${PHASE} patches=${PATCHLIST} patchtop= ${STAGE} workers=16

##{ echo only4dtest; echo Onl4dtest; echo Weblogic13; } | adop phase=fs_clone
  grep -i FAILED $APPL_TOP/admin/$TWO_TASK/log/$PATCH.log >/tmp/patchtmp.log
  if [ `grep FAILED /tmp/patchtmp.log | wc -l` -ne 0 ]
  then
    echo "Patch $PATCH failed"
    cat $APPL_TOP/admin/$TWO_TASK/log/$PATCH.log |mailx -s "Patch $PATCH failed on `hostname` instance $TWO_TASK" sumit.davre@commonspirit.org
    rm /tmp/patchtmp.log
    rm -rf $STAGE/$PATCH
    exit 1
  else
    tail -10 $APPL_TOP/admin/$TWO_TASK/log/$PATCH.log |mailx -s "$PATCH applied on `hostname` instance $TWO_TASK" sumit.davre@commonspirit.org
    rm /tmp/patchtmp.log
    rm -rf $STAGE/$PATCH
  fi


#echo "Disabling maintenance mode"
#               sqlplus apps/$PSWD @$AD_TOP/patch/115/sql/adsetmmd.sql DISABLE
#
#exit


