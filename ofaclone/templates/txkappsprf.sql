REM $Header: txkappsprf.sql 120.0.12020000.2 2013/03/04 11:09:43 ttsharma noship $
REM +========================================================================+
REM |  Copyright (c) 1997 Oracle Corporation Redwood Shores, California, USA
REM |                          All Rights Reserved
REM +========================================================================+
REM | FILENAME
REM |   txkappsprf.sql
REM |
REM | DESCRIPTION
REM |   Script to update profile options for Applications by AutoConfig
REM |
REM | ARGUMENTS
REM |
REM | NOTES
REM |   The script defines or updates the following profile options.
REM |     FND_VALIDATION_LEVEL            :      ERROR
REM |     FND_FUNCTION_VALIDATION_LEVEL   :      ERROR
REM |     FRAMEWORK_VALIDATION_LEVEL      :      ERROR
REM |
REM | HISTORY
REM ===========================================================================
REM dbdrv: none
REM
REM $AutoConfig$
REM


WHENEVER SQLERROR EXIT FAILURE ROLLBACK;
SET VERIFY OFF
WHENEVER OSERROR  EXIT FAILURE ROLLBACK;

REM
REM This script is run from a nolog session ; connect first.
REM
connect &1/&2@&3

spool %s_config_home%/admin/log/txkappsprf.txt;

SET SERVEROUTPUT ON SIZE 200000

DEFINE CTX="%s_contextname%"
DEFINE VALIDATION_LEVEL = "ERROR"
DEFINE SITE_NAME = "EPROD - Production - Copy of EPROD as of JAN 21 20222/"

begin

  --
  -- Validation level profiles
  --

  adx_prf_pkg.set_profile(0, 'FND_VALIDATION_LEVEL',
              10001, 0,
              '&VALIDATION_LEVEL',
              NULL, '&CTX');

  adx_prf_pkg.set_profile(0, 'FND_FUNCTION_VALIDATION_LEVEL',
              10001, 0, 
              '&VALIDATION_LEVEL',
              NULL, '&CTX');

  adx_prf_pkg.set_profile(0, 'FRAMEWORK_VALIDATION_LEVEL',
              10001, 0, 
              '&VALIDATION_LEVEL',
              NULL, '&CTX');

  adx_prf_pkg.set_profile(0, 'SITENAME',
              10001, 0,
              '&SITE_NAME',
              NULL, '&CTX');

end;
/

commit;
exit;
/
