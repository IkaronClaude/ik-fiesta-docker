/* chargedbuffer_repro.c - Character.exe's charged-buffer read, call for call, outside the game.
 *
 * Symptom: permanent charged effects (Iron Case, etc.) are saved correctly - tCharacterChargedBuffer holds
 * the rows - but come back empty after a relog. Character.exe reads them in 0x46D680 with exactly this
 * sequence (read from its disassembly; ODBC32 is imported by ordinal, see tools in ik-fiesta-patch-recipes):
 *
 *   Database::InitEnv     SQLSetEnvAttr(SQL_ATTR_ODBC_VERSION, SQL_OV_ODBC2)      <- an ODBC 2 application
 *   0x45AA40              SQLCloseCursor; SQLBindParameter(1, INPUT, SQL_C_ULONG, SQL_INTEGER, 0, 0, &charNo)
 *                         SQLExecDirect("{CALL p_Char_GetChargedBufferAll(?)}")
 *   0x46D6C9 ...          SQLFetch, then per row, with the RETURN VALUE NEVER CHECKED:
 *     0x44FC60            SQLGetData(col, SQL_C_ULONG  (-18),  4)   nKey
 *     0x44FC30            SQLGetData(col, SQL_C_USHORT (-17),  2)   nID
 *     0x44FDA0 x2         SQLGetData(col, SQL_C_TIMESTAMP (11), 16) dUseDate, dEndDate
 *
 * This does the same and prints every return code and value, so the failing call and its data are visible
 * without a game client. Build 32-bit (Character.exe is PE32) and run under Wine in the character container:
 *
 *   cl /nologo chargedbuffer_repro.c odbc32.lib
 *   TDSDUMP=/tmp/tds.log wine chargedbuffer_repro.exe "<connection string>" <charNo>
 *
 * Exit code 0 = every column of every row read successfully; 1 = at least one SQLGetData failed.
 */
#include <windows.h>
#include <sql.h>
#include <sqlext.h>
#include <stdio.h>
#include <string.h>

static void diag(SQLSMALLINT type, SQLHANDLE h, const char* what) {
    SQLCHAR state[6], msg[512];
    SQLINTEGER native;
    SQLSMALLINT len, i = 1;
    while (SQLGetDiagRec(type, h, i++, state, &native, msg, sizeof(msg), &len) == SQL_SUCCESS)
        printf("    %s: [%s] native %ld: %s\n", what, state, (long)native, msg);
}

static int ok(SQLRETURN r) { return r == SQL_SUCCESS || r == SQL_SUCCESS_WITH_INFO; }

int main(int argc, char** argv) {
    if (argc < 3) { printf("usage: %s <connection string> <charNo> [ctype]\n", argv[0]); return 2; }
    SQLUINTEGER charNo = (SQLUINTEGER)atoi(argv[2]);
    SQLSMALLINT tsType = argc > 3 ? (SQLSMALLINT)atoi(argv[3]) : SQL_C_TIMESTAMP;   /* 11, as the exe */
    SQLHENV env; SQLHDBC dbc; SQLHSTMT st;
    SQLRETURN r;
    int failed = 0;

    SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &env);
    SQLSetEnvAttr(env, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC2, 0);     /* as Database::InitEnv */
    SQLAllocHandle(SQL_HANDLE_DBC, env, &dbc);
    r = SQLDriverConnect(dbc, NULL, (SQLCHAR*)argv[1], SQL_NTS, NULL, 0, NULL, SQL_DRIVER_NOPROMPT);
    printf("connect: %d\n", r);
    if (!ok(r)) { diag(SQL_HANDLE_DBC, dbc, "connect"); return 2; }
    SQLAllocHandle(SQL_HANDLE_STMT, dbc, &st);
    r = SQLExecDirect(st, (SQLCHAR*)"USE World00_Character; SET LOCK_TIMEOUT 5000", SQL_NTS);
    printf("use db: %d\n", r);
    SQLCloseCursor(st);
    SQLFreeStmt(st, SQL_CLOSE);

    /* 0x45AA40 */
    SQLCloseCursor(st);
    r = SQLBindParameter(st, 1, SQL_PARAM_INPUT, SQL_C_ULONG, SQL_INTEGER, 0, 0, &charNo, 0, NULL);
    printf("bind charNo=%lu: %d\n", (unsigned long)charNo, r);
    r = SQLExecDirect(st, (SQLCHAR*)"{CALL p_Char_GetChargedBufferAll(?)}", SQL_NTS);
    printf("exec: %d\n", r);
    if (!ok(r)) { diag(SQL_HANDLE_STMT, st, "exec"); return 2; }

    printf("reading dates as C type %d (%s)\n", tsType,
           tsType == SQL_C_TIMESTAMP ? "SQL_C_TIMESTAMP, ODBC 2 - what the exe uses" :
           tsType == SQL_C_TYPE_TIMESTAMP ? "SQL_C_TYPE_TIMESTAMP, ODBC 3" : "?");
    int rows = 0;
    while (ok(SQLFetch(st))) {
        SQLUINTEGER key = 0xDEADBEEF;
        SQLUSMALLINT id = 0xBEEF;
        TIMESTAMP_STRUCT use, end;
        memset(&use, 0xCC, sizeof(use));      /* the exe's buffers are uninitialised stack: show that */
        memset(&end, 0xCC, sizeof(end));
        SQLRETURN r1 = SQLGetData(st, 1, SQL_C_ULONG, &key, 4, NULL);
        SQLRETURN r2 = SQLGetData(st, 2, SQL_C_USHORT, &id, 2, NULL);
        SQLRETURN r3 = SQLGetData(st, 3, tsType, &use, 16, NULL);
        if (!ok(r3)) diag(SQL_HANDLE_STMT, st, "getdata col3");
        SQLRETURN r4 = SQLGetData(st, 4, tsType, &end, 16, NULL);
        if (!ok(r4)) diag(SQL_HANDLE_STMT, st, "getdata col4");
        printf("row %d: key %lu (%d)  id %u (%d)  use %04d-%02u-%02u %02u:%02u (%d)  end %04d-%02u-%02u %02u:%02u (%d)\n",
               rows, (unsigned long)key, r1, id, r2,
               use.year, use.month, use.day, use.hour, use.minute, r3,
               end.year, end.month, end.day, end.hour, end.minute, r4);
        if (!ok(r1) || !ok(r2) || !ok(r3) || !ok(r4)) failed = 1;
        rows++;
    }
    printf("rows: %d  %s\n", rows, failed ? "SOME SQLGetData FAILED" : "all columns read");
    return failed;
}
