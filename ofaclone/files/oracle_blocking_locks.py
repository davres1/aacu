import configparser, cx_Oracle, datetime, time
from datetime import date, datetime
import getpass, re, ast
import smtplib
import string
import random

from cx_Oracle import DatabaseError
from dateutil.relativedelta import relativedelta

import paramiko
import logging
from O365 import Account,Connection,FileSystemTokenBackend

logging.basicConfig (format='%(levelname)s:%(message)s', level=logging.DEBUG)
logging.basicConfig (filename='dbpassword.log', level=logging.DEBUG)

def start_database(ssh_host, ssh_user, db_name, admin_mail):
    """
    Connects to a remote server via SSH and starts the Oracle database.
    """
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(ssh_host, username=ssh_user)

        # Command to start the database.
        # This assumes 'oraenv' can set the environment for the given SID
        # and that 'dbstart' is configured.
        # A more direct approach could also be used if dbstart is not reliable.
        command = f"""
export ORAENV_ASK=NO
export ORACLE_SID={db_name}
. oraenv
sqlplus / as sysdba <<EOF
startup;
exit;
EOF
"""
        stdin, stdout, stderr = client.exec_command(command)
        output = stdout.read().decode()
        errors = stderr.read().decode()
        logging.info(f"Startup script output for {db_name} on {ssh_host}:\n{output}")
        if errors:
            logging.error(f"Startup script errors for {db_name} on {ssh_host}:\n{errors}")
        send_email(admin_mail, f'ACTION: Database {db_name} was down and a startup was initiated.', f'The database {db_name} was detected as down and an automatic startup was attempted on {ssh_host}.\n\nOutput:\n{output}\n\nErrors:\n{errors}')
        client.close()
    except Exception as e:
        logging.error(f"Failed to SSH to {ssh_host} and start database {db_name}: {e}")
        send_email(admin_mail, f'ALERT: Failed to start database {db_name}', f'An attempt to automatically start database {db_name} on {ssh_host} failed.\n\nError: {e}\n\nPlease investigate manually.')


def blockinglocks(password,dbname):
    while True:
            try:
                ora = cx_Oracle.Connection ('system' ,password,dbname)
                print(dbname)
                break
            except cx_Oracle.DatabaseError as errmsg:
                print ("Error attempting to log in: {0}".format (errmsg))
            break

    try:

        # sql = ''' SELECT s1.sid, s1.serial#,s1.username,s1.program,s1.machine  FROM v$lock l1, v$session s1, v$lock l2, v$session s2
        #         WHERE s1.sid=l1.sid AND s2.sid=l2.sid
        #         AND l1.BLOCK=1 AND l2.request > 0
        #         AND l1.id1 = l2.id1
        #         AND l1.id2 = l2.id2'''


        sql = '''SELECT s1.sid, s1.serial#,s1.username,s1.program,s1.machine
            FROM V$SESSION s1
            WHERE SID IN (select DISTINCT blocking_session
            FROM v$session WHERE STATE IN ('WAITING') AND wait_class != 'Idle' AND last_call_et > 120)
            AND (username IS NOT NULL AND username NOT IN ('SYS','SYSTEM') ) '''
        ora = cx_Oracle.Connection ('system', password, dbname)
        curs = ora.cursor ()
        curs.execute (sql)
        data = curs.fetchall ()
        #luser = data.row[2]
        #lmachine = data.row[3]
        #lprogram = data.row[4]
        print(len(data))
        if len(data) < 1 :
            print("")
        else:
            for sid,serial,luser,lprogram,lmachine in data:
                print(sid,serial)
                sql1= "alter system kill session '"+ str(sid) + ","+ str(serial) + "' immediate"
                print(sql1)
                curs.execute (sql1)
                send_email (adminmail, 'Automated Email: Blocking session on %s' % (dbname),'USER = %s, PROGRAM = %s , MACHINE = %s and SID = %s and SERIAL# = %s are blocking other sessions.Its being KILLED now.' % (luser, lprogram, lmachine, sid, serial))
    except cx_Oracle.DatabaseError as errmsg:
                print ("Error attempting to log in: {0}".format (errmsg))


def send_email(to_addr, sub, message):
    scopes = ['message_all']
    token_backend = FileSystemTokenBackend(token_path='/DEVOPS/python', token_filename='o365_token.txt')
    account = Account (credentials=('407f381f-ba93-4f3e-97d1-903fa493ca98','G_ZUBCz66?4Qfo9LPsd.y.p?1OQSrPSv'),token_backend=token_backend,scopes=['message_all'])
    #Connection.refresh_token
    for i in to_addr:
        print (i)
        m = account.new_message ()
        m.to.add (i)
        m.subject = sub
        m.body = message
        m.send ()


if __name__ == "__main__":

    config = configparser.ConfigParser ()
    config.read ('/DEVOPS/python/DB_LIST.ini')
    # def info(DB):
    config.read ('/DEVOPS/python/DB_LIST.ini')
    for DB in config.sections ():
        i = ast.literal_eval (config.get (DB, 'username'))
        syspass = config.get (DB, 'syspass')
        dbname = DB
        adminmail = config.get (DB, 'emaillist')
        ssh_host = config.get(DB, 'ssh_host', fallback='oracle')
        ssh_user = config.get(DB, 'ssh_user', fallback='server')
        # print(type(adminmail))
        adminmail = adminmail.split (",")
        try:
                    cx_Oracle.Connection ('system', syspass, DB)
                    print(datetime.today())
                    print(DB)
                    print ("system" + " password in " + DB + " is Working \n")
                    blockinglocks(syspass, DB)
        except cx_Oracle.DatabaseError as exc:
                    error, = exc.args
                    print ("Oracle-Error-Code:", error.code)
                    print ("Oracle-Error-Message:", error.message)
                    if error.code == 1017:
                        print ("System user in " + DB)
                    elif any (str (error.code) in s for s in ['12170', '12154']):
                        send_email (adminmail, 'Tns issue with database %s' % (DB), error.message)
                    # ORA-01034: ORACLE not available
                    if error.code == 1034:
                        print(f"Database {DB} is down. Attempting to start it.")
                        if all([ssh_host, ssh_user]):
                            start_database(ssh_host, ssh_user, DB, adminmail)
                        else:
                            send_email(adminmail, f'ALERT: Database {DB} is down', f'Database {DB} is down. SSH credentials not configured for automatic startup.')
                    elif error.code == 1017:
                        print ("Invalid credentials for system user in " + DB)
                    elif any(str(error.code) in s for s in ['12170', '12154', '12514']):
                        send_email(adminmail, f'TNS issue with database {DB}', error.message)