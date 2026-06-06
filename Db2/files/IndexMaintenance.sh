#!/usr/bin/env bash
# IndexMaintenance.sh — cron-scheduled REORG + RUNSTATS for tables flagged by
# REORGCHK. NOT a chatbot intent. Heavy; scheduled monthly.
source "$(dirname "$0")/lib/db2_common.sh"

DBS="${*:-$(list_databases)}"
rc=0

for db in $DBS; do
    log "REORG/RUNSTATS pass on $db"
    # Tables pending reorganization.
    tables="$(printf '%s' "SELECT RTRIM(TABSCHEMA) || '.' || RTRIM(TABNAME) FROM SYSIBMADM.ADMINTABINFO WHERE REORG_PENDING='Y';" | sqlx "$db" 2>/dev/null | awk 'NF{print $1}')"
    for t in $tables; do
        printf '%s\n' "CALL SYSPROC.ADMIN_CMD('REORG TABLE ${t}');" | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
        printf '%s\n' "CALL SYSPROC.ADMIN_CMD('RUNSTATS ON TABLE ${t} WITH DISTRIBUTION AND DETAILED INDEXES ALL');" | sql "$db" >>"$LOG_FILE" 2>&1 || rc=1
    done
done
exit $rc
