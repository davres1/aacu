import cx_Oracle
import datetime
import time
from datetime import date, datetime
import subprocess
import sys

from cx_Oracle import DatabaseError
import logging


logging.basicConfig(format='%(levelname)s:%(message)s', level=logging.DEBUG)
logging.basicConfig(filename='dbpassword.log', level=logging.DEBUG)


def adop_apply(req_phase, patches, appspass, systempass, weblogicpass, options, patchtop='/stage/DB_Patches/adop', hotpatch='no', allnodes='YES', workers=16, force='no', restart='no', abandon='no'):
    for i in options:
        if i == 'restart' and 'abandon' in options:
            abandon = 'yes'
        elif i == 'restart' and 'abandon' not in options:
            restart = 'yes'
        elif i == 'downtime':
            downtime = 'yes'
        elif i == 'hotpatch':
            hotpatch = 'yes'
            req_phase = ['apply']
        elif i == 'abandon' and 'restart' not in options:
            abandon = 'yes'
            restart = 'no'
    phase = ','.join(req_phase)

    cmd = "{ echo " + appspass + "; echo " + systempass + "; echo " + weblogicpass + "; } | adop phase=" + phase + " patches=" + \
        str(patches) + " patchtop=" + patchtop + " workers=" + str(workers) + " hotpatch=" + hotpatch + \
        " allnodes=" + allnodes + " force=" + force + \
        " restart=" + restart + " abandon=" + abandon + " downtime=" + downtime 
    print(cmd)
    out = subprocess.run(cmd, shell=True, capture_output=True)
    print(out.stderr)


def adop_check(password, dbname):
    while True:
        try:
            ora = cx_Oracle.Connection('apps', password, dbname)
            print(dbname)
            break
        except cx_Oracle.DatabaseError as errmsg:
            print("Error attempting to log in: {0}".format(errmsg))
        break

    try:

        sql = '''select adop_session_id,prepare_status,apply_status,finalize_status,cutover_status,cleanup_status,status,node_name,node_type from ad_adop_sessions  where adop_session_id in (select max(adop_session_id) from ad_adop_sessions) order by adop_session_id desc '''
        ora = cx_Oracle.Connection('apps', password, dbname)
        curs = ora.cursor()
        curs.execute(sql)
        data = curs.fetchall()
        # luser = data.row[2]
        # lmachine = data.row[3]
        # lprogram = data.row[4]
        # print(len(data))
        # print(data.column)
        for adop_session_id, prepare_status, apply_status, finalize_status, cutover_status, cleanup_status, status, node_name, node_type in data:

            if node_type in ['slave'] and status == 'C':  # C
                print(
                    f"all patch cycle ran fine on node {node_name} with session:{adop_session_id}")
                return (['CLEAR', 'prepare', 'apply', 'finalize', 'cutover', 'cleanup'])
                # return (['CLEAR','apply','finalize','cutover','cleanup'])
                break
            elif node_type in ['master', 'slave'] and status == 'F':  # F
                if prepare_status == 'F':
                    print(
                        f"prepare_status Failed on {node_name} with session:{adop_session_id}")
                    return (['FAIL', 'apply', 'finalize', 'cutover', 'cleanup'])
                    break
                elif apply_status == 'F':
                    print(
                        f"apply_status Failed on {node_name} with session:{adop_session_id}")
                    return (['FAIL', 'apply', 'finalize', 'cutover', 'cleanup'])
                    break
                elif finalize_status == 'F':
                    print(
                        f"finalize_status Failed on {node_name} with session:{adop_session_id}")
                    return (['FAIL', 'finalize', 'cutover', 'cleanup'])
                    break
                elif cutover_status == 'F':
                    print(
                        f"cutover_status Failed on {node_name} with session:{adop_session_id}")
                    return (['FAIL', 'cutover', 'cleanup'])
                    break
                elif cleanup_status == 'F':
                    print(
                        f"cleanup_status Failed on {node_name} with session:{adop_session_id}")
                    return (['FAIL', 'cleanup'])
                    break
            elif node_type in ['master', 'slave'] and status == 'R':
                if prepare_status == 'R':
                    print(
                        f"prepare_status is running on {node_name} with session:{adop_session_id}")
                    return (['NOOP', 'apply', 'finalize', 'cutover', 'cleanup'])
                    break
                elif apply_status == 'R':
                    print(
                        f"apply_status is running on {node_name} with session:{adop_session_id}")
                    return (['NOOP', 'apply', 'finalize', 'cutover', 'cleanup'])
                    break
                elif finalize_status == 'R':
                    print(
                        f"finalize_status is running on {node_name} with session:{adop_session_id}")
                    return (['NOOP', 'cutover', 'cleanup'])
                    break
                elif cutover_status == 'R':
                    print(
                        f"cutover_status is running on {node_name} with session:{adop_session_id}")
                    return (['NOOP', 'cleanup'])
                    break
                elif cleanup_status == 'R':
                    print(
                        f"cleanup_status Failed on {node_name} with session:{adop_session_id}")
                    return (['NOOP', 'cleanup'])
                    break
            elif node_type in ['master', 'slave'] and status == 'N':  # R
                print('3rd')
                if prepare_status == 'N':
                    print(
                        f"prepare_status has not been completed on {node_name} with session:{adop_session_id}")
                    return (['CLEAR', 'prepare', 'apply', 'finalize', 'cutover', 'cleanup'])
                elif apply_status == 'N' and prepare_status == 'Y':
                    print(
                        f"apply_status has not been completed on {node_name} with session:{adop_session_id}")
                    return (['CLEAR', 'apply', 'finalize', 'cutover', 'cleanup'])
                elif finalize_status == 'N' and apply_status == 'Y':
                    print(
                        f"finalize_status has not been completed on {node_name} with session:{adop_session_id}")
                    return (['CLEAR', 'finalize', 'cutover', 'cleanup'])
                elif cutover_status == 'N' and finalize_status == 'Y':
                    print(
                        f"cutover_status has not been completed on {node_name} with session:{adop_session_id}")
                    return (['CLEAR', 'cutover', 'cleanup'])
                elif cleanup_status == 'N' and cutover_status == 'Y':
                    print(
                        f"cleanup_status has not been completed on {node_name} with session:{adop_session_id}")
                    return (['CLEAR', 'cleanup'])
    except cx_Oracle.DatabaseError as errmsg:
        print("Error attempting to log in: {0}".format(errmsg))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(len(sys.argv))
        print(
            "Please use {sys.argv[0]} <phase i.e. prepare,apply etc> <patches i.e 123,1234,1234>")
        exit(1)

    appspass = sys.argv[1]
    systempass = sys.argv[2]
    weblogicpass = sys.argv[3]
    DB = sys.argv[4]
    req_phase = sys.argv[5].split(',')
    print(req_phase)
    patches = sys.argv[6]
    options = sys.argv[7].split(',')
    patchtop = sys.argv[8]


    timer = 1
    try:
        cx_Oracle.Connection('apps', appspass, DB)
        print(datetime.today())
        print("apps" + " password in " + DB + " is Working \n")
        phase_left = adop_check(appspass, DB)
        print(f"{phase_left[0]},{phase_left[1]},{req_phase[0]}")

        while phase_left[0] == 'NOOP' and timer < 5:
            time.sleep(1)
            timer += 1
            phase_left = adop_check(appspass, DB)
            print("Waiting on adop to get finished for 3 mins....")

        if phase_left[0] == 'CLEAR' and phase_left[1] == req_phase[0]:
            print(
                f"Privous Patch cycle is clear and we can open new cycle and apply patches")
            adop_apply(req_phase, patches)
        elif phase_left[1] != req_phase[0] and req_phase[0] in ['prepare', 'apply'] and phase_left[1] not in ['finalize', 'cutover', 'cleanup']:
            if phase_left[1] == "apply" and req_phase[0] == "prepare":
                print("removing already applied phase")
                req_phase.remove('prepare')
                print("Running adop with option {req_phase}")
                adop_apply(req_phase, patches,appspass,systempass,weblogicpass,options)
            elif phase_left[1] in ['prepare'] and req_phase[0] in ['apply']:
                req_phase.insert(0, 'prepare')
                print("Running adop with option {req_phase}")
                adop_apply(req_phase, patches,appspass,systempass,weblogicpass,options)
            else:
                print("Running adop with option {req_phase}")
                adop_apply(req_phase, patches,appspass,systempass,weblogicpass,options)
        elif phase_left[1] != req_phase[0] and phase_left[1] in ['finalize', 'cutover', 'cleanup'] and req_phase[0] in ['cutover', 'cleanup']:
            print(f"Running 'finalize','cutover','cleanup' phase first")
            adop_apply(phase_left[1:], patches,appspass,systempass,weblogicpass,options)
        # elif phase_left[1] != req_phase[0] and phase_left[1] == "apply" and req_phase[0] == "prepare":
        #     print("removing already applied phase")
        #     req_phase.remove[0]
        #     print ("Running adop with option {req_phase}")
        #     adop_apply(req_phase,patches,appspass,systempass,weblogicpass,options)
        # elif phase_left[1] != req_phase[0] and phase_left[1] in ['prepare'] and   req_phase[0] in ['apply']:
        #     print ("Running adop with option {req_phase}")
        #     adop_apply(req_phase,patches,appspass,systempass,weblogicpass,options)
        elif phase_left[1] != req_phase[0] and req_phase[0] in ['finalize', 'cutover', 'cleanup']:
            print(f"Running {req_phase}")
            adop_apply(req_phase, patches,appspass,systempass,weblogicpass,options)

        if phase_left[0] == 'NOOP':
            print(
                f"Privous Patch cycle is still running and cant run patches at this time")
            exit(0)
        if phase_left[0] == 'FAIL' and phase_left[1] in ['apply']:
            adop_apply(phase_left[1:],patches,appspass,systempass,weblogicpass,'adandon')
            print(
                f"Privous Patch cycle {phase_left[1]} phase was failed.Please check log and rerun the process")
        else:
            print(
                f"Privous Patch cycle {phase_left[1]} phase was failed.Please check log and rerun the process")

    except cx_Oracle.DatabaseError as exc:
        error, = exc.args
        print("Oracle-Error-Code:", error.code)
        print("Oracle-Error-Message:", error.message)
        if error.code == 1017:
            print('apps' + " in " + DB)
        elif any(str(error.code) in s for s in ['12170', '12154']):
            print('Tns issue with database %s' % (DB), error.message)
