-- Simple output
  BEGIN
    DBMS_OUTPUT.PUT_LINE('Hello World');
  END;

  -- Multiple lines
  BEGIN
    DBMS_OUTPUT.PUT_LINE('Line 1');
    DBMS_OUTPUT.PUT_LINE('Line 2');
    DBMS_OUTPUT.PUT_LINE('Line 3');
  END;

  -- Empty output (no PUT_LINE calls)
  BEGIN
    NULL;
  END;

  -- Long line (near 32767 char limit)
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('X', 1000, 'X'));
  END;

  -- Special characters
  BEGIN
    DBMS_OUTPUT.PUT_LINE('Quote: '' and backslash: \');
    DBMS_OUTPUT.PUT_LINE('Unicode: café ñ 中文');
  END;

  -- DECLARE block
  DECLARE
    v_msg VARCHAR2(100) := 'From variable';
  BEGIN
    DBMS_OUTPUT.PUT_LINE(v_msg);
  END;

  -- Should NOT be detected as PL/SQL (regular SELECT)
  SELECT * FROM dual;

  -- Should be detected (CREATE PROCEDURE)
  CREATE OR REPLACE PROCEDURE test_proc AS
  BEGIN
    NULL;
  END;

  -- CALL statement
  CALL DBMS_OUTPUT.PUT_LINE('Direct call');

  -- Division by zero
  BEGIN
    DBMS_OUTPUT.PUT_LINE(1/0);
  END;

  -- Undefined variable
  BEGIN
    DBMS_OUTPUT.PUT_LINE(undefined_var);
  END;


DECLARE
    v_cursor SYS_REFCURSOR;
    v_col1 VARCHAR2(100);
    v_col2 NUMBER;
  BEGIN
    OPEN v_cursor FOR SELECT 'Hello' AS col1, 123 AS col2 FROM DUAL;
    LOOP
      FETCH v_cursor INTO v_col1, v_col2;
      EXIT WHEN v_cursor%NOTFOUND;
      DBMS_OUTPUT.PUT_LINE(v_col1 || '|' || v_col2);
    END LOOP;
    CLOSE v_cursor;
  END;


DECLARE
    -- Simulating OUT params
    v_count NUMBER;
    v_cursor SYS_REFCURSOR;
    -- Cursor fetch variables
    v_col1 VARCHAR2(100);
    v_col2 NUMBER;
  BEGIN
    -- Simulate procedure that sets OUT params
    v_count := 42;
    OPEN v_cursor FOR SELECT 'Row1' AS name, 100 AS value FROM DUAL
                      UNION ALL
                      SELECT 'Row2', 200 FROM DUAL;
    -- Print scalar OUT param
    DBMS_OUTPUT.PUT_LINE('count: ' || v_count);
    -- Fetch from cursor OUT param
    LOOP
      FETCH v_cursor INTO v_col1, v_col2;
      EXIT WHEN v_cursor%NOTFOUND;
      DBMS_OUTPUT.PUT_LINE(v_col1 || '|' || v_col2);
    END LOOP;
    CLOSE v_cursor;
  END;


BEGIN
    OPEN :result /*CURSOR*/ FOR SELECT 'Hello' AS col1, 123 AS col2 FROM DUAL
      UNION ALL SELECT 'World', 456 FROM DUAL;
  END;


BEGIN
    OPEN :cur1 /*CURSOR*/ FOR
      SELECT 'Hello' AS col1, 123 AS col2 FROM DUAL
      UNION ALL SELECT 'World', 456 FROM DUAL;
    OPEN :cur2 /*CURSOR*/ FOR
      SELECT SYSDATE AS today, USER AS username FROM DUAL;
  END;


BEGIN
    DBMS_OUTPUT.PUT('Hello ');
    DBMS_OUTPUT.PUT_LINE('World');
  END;

BEGIN
    DBMS_OUTPUT.PUT_LINE('Line 1');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Line 3');
  END;


EXPLAIN PLAN FOR
MERGE INTO sas_principals sp
  USING (
      SELECT DISTINCT
          LOWER(REGEXP_SUBSTR(p.attrval, 'cn=([^,+]+)', 1, 1, NULL, 1)) AS principal_name
      FROM fusion_opss.jps_attrs p
      JOIN fusion_opss.jps_attrs rcn ON rcn.jps_dn_entryid = p.jps_dn_entryid
      WHERE p.attrname = 'orcljaznprincipal'
        AND p.attrval LIKE '%WLSUserImpl%'
        AND REGEXP_SUBSTR(p.attrval, 'cn=([^,+]+)', 1, 1, NULL, 1) NOT LIKE '%\_APPID' ESCAPE '\'
        AND rcn.attrname = 'cn'
        AND rcn.attrval IN (
            SELECT name FROM sas_roles
            WHERE json_value(role_def_json, '$.isLinked') = 'true'
        )
        AND p.jps_dn_entryid IN (
            SELECT entryid FROM fusion_opss.jps_dn
            WHERE parentdn LIKE '%cn=jpscontext,%,cn=%,cn=roles,'
        )
        AND NOT EXISTS (
            SELECT 1 FROM sas_principals sp2
            WHERE sp2.deleted_flag = 0
              AND LOWER(sp2.name) = LOWER(REGEXP_SUBSTR(p.attrval, 'cn=([^,+]+)', 1, 1, NULL, 1))
        )
  ) src
  ON (LOWER(sp.name) = src.principal_name AND sp.deleted_flag = 0)
  WHEN NOT MATCHED THEN INSERT (
      principal_id, name, source_idp, principal_source, principal_origin_guid,
      principal_json, schema_version, created_by, creation_date,
      last_updated_by, last_update_date, deleted_flag
  ) VALUES (
      sas_principals_s.NEXTVAL,
      src.principal_name,
      'FAIDM',
      'FAIDM',
      'sas_' || SUBSTR(STANDARD_HASH(src.principal_name, 'SHA256'), 1, 16),
      '{"type":"user","sourceIDP":"FAIDM","originGuid":"sas_' || SUBSTR(STANDARD_HASH(src.principal_name, 'SHA256'), 1, 16) || '"}',
      '1.0.0',
      'sas_opss_sync',
      SYSDATE,
      'sas_opss_sync',
      SYSDATE,
      0
  );

  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);


SELECT col.column_name, col.data_type FROM sys.all_tab_columns col WHERE col.owner = 'FUSION' AND table_name = 'sas_principals';
SELECT COUNT(*) FROM sys.all_tab_columns WHERE owner = 'FUSION';
select name from sas_principals fetch first 210 rows only;
SELECT DISTINCT owner, table_name FROM all_tab_columns WHERE UPPER(table_name) = 'SAS_PRINCIPALS';
SELECT * FROM all_synonyms WHERE UPPER(synonym_name) = 'SAS_PRINCIPALS';
select count(*) from sas_principals sp where sp.CREATED_BY = 'sas_opss_sync';


-- DBEE_OPTS: {"binds":{"id":"42","id2":"99"}}
SELECT :id AS bind_id, :id2 as bind_id2 FROM dual;

-- DBEE_OPTS: {"binds":{"num":"int:41","d":"date:2026-02-10","ts":"timestamp:2026-02-10T11:22:33Z","s":"str:001"}}
SELECT :num + 1 AS plus_one,
       TO_CHAR(:d, 'YYYY-MM-DD') AS d,
       TO_CHAR(:ts, 'YYYY-MM-DD HH24:MI:SS') AS ts,
       :s AS s
FROM dual;
