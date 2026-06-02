. ~/.bash_profile
Curr_log=/tmp/$TWO_TASK
TMP_UPD=/tmp/wf_up_${TWO_TASK}.sql
cat /dev/null > ${Curr_log}
wf_config_file=$1
APPSLOGIN=apps/{{ tgt_apps_pwd }}
. {{ app_tgt_mount }}/EBSapps.env RUN
wf_val_check()
{

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "$1"
for i in `awk -F ',' '{print $2}' ${wf_config_file}`
do
sqlplus -s $APPSLOGIN <<EOF
set head off
set feedback off
set verify off;
SELECT
    'You have selected parameter : '
     || c.display_name
     || wf_core.newline
     || 'Current value of parameter  : '
     || a.parameter_value
FROM
    fnd_svc_comp_param_vals a,
    fnd_svc_comp_params_tl c
WHERE
        c.parameter_id = a.parameter_id
    AND
        a.component_parameter_id = to_number(nvl(
            '${i}',
            '0'
        ) )
    AND
        c.language = 'US';
exit;
EOF
done
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

wf_upd_val()
{
echo "updating values"
while read line; 
do 
new_val="`echo $line|awk -F ',' '{print $3}' `"
par_id="`echo $line|awk -F ',' '{print $2}'`"
echo "UPDATE fnd_svc_comp_param_vals
SET    parameter_value = nvl('"$new_val"', parameter_value)
WHERE  component_parameter_id = to_number(nvl('"$par_id"', '0'));"
done < ${wf_config_file} > ${TMP_UPD}

sqlplus -s $APPSLOGIN <<EOF
set head off
set feedback off
set verify off;
@${TMP_UPD}
commit;
exit;
EOF
}

wf_val_check old
wf_upd_val
wf_val_check new
