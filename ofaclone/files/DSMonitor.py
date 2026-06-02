#========================================================
# ScriptFile: DSMonitor.py
# Author : Pavan Devarakonda
# Purpose : Multi Datasource monitoring with Server wise
#========================================================
urldict={}
def conn():
    try:        
        print 'Connecting to Admin server....'
        connect(username, password, adminurl)
    except:
        print 'Admin Server NOT in RUNNING state....'


def initialize():
    conn()
    try:
        serverlist=['app01','app02','app03'...]
        for s in serverlist:
            cd("/Servers/"+s)
            urldict[s]='t3://'+get('ListenAddress')+':'+str(get('ListenPort'))
            JDBCStat()
    except:
        print 'issue in accessing JDBC Pool'

def printline():
    print '------------------------------------------------------------'

def printHeadr():
    print 'JDBC CONNECTION POOLS STATISTICS'
    print ' '
    print 'Name      Max      Active  Active   WaitSecs Waiting  State'
    print '          capacity Current HighCnt  HighCnt  Count'
    printline()

def getJDBCDetails():
    pname=get("Name")
    pmcapacity=get("CurrCapacityHighCount")
    paccc = get("ActiveConnectionsCurrentCount")
    pachc = get("ActiveConnectionsHighCount")
    pwshc = get("WaitSecondsHighCount")
    pwfccc = get("WaitingForConnectionCurrentCount")
    pstate = get("State")
    print '%10s %7d %7d %7d %7d %7d %10s' % (pname,pmcapacity,paccc,pachc, pwshc,pwfccc,pstate)
    print ' '

def JDBCStat():
    Ks = urldict.keys()
    Ks.sort()
    printHeadr()
    for s in Ks:
        try:
            connect(user, passwd,urldict[s])
            serverRuntime()
            cd('JDBCServiceRuntime/'+s+'/JDBCDataSourceRuntimeMBeans/')
            print ' '+s
            printline()
            DSlist=ls(returnMap='true')
            for ds in DSlist:
                cd(ds)
                getJDBCDetails()
                cd('..')
        except:
    #pass
            print ('Exception')
            quit()

def quit():
    print (' Hit any key to Re-RUN this script ...')
    Ans = raw_input("Are you sure Quit from WLST... (y/n)")
    if (Ans == 'y'):
        disconnect()
        stopRedirect()
    else:
        JDBCStat()

if __name__== "main":
    redirect('./logs/JDBCCntwlst.log', 'false')
    initialize()
    print ('done')
