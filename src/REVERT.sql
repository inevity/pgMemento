-- REVERT.sql
--
-- Author:      Felix Kunde <felix-kunde@gmx.de>
--
--              This skript is free software under the LGPL Version 3
--              See the GNU Lesser General Public License at
--              http://www.gnu.org/copyleft/lgpl.html
--              for more details.
-------------------------------------------------------------------------------
-- About:
-- This script provides functions to revert single transactions and entire database
-- states.
-- 
-------------------------------------------------------------------------------
--
-- ChangeLog:
--
-- Version | Date       | Description                                   | Author
-- 0.3.0     2016-04-29   splitting up the functions to match the new     FKun
--                        logging behavior for table events
-- 0.2.2     2016-03-08   added another revert procedure                  FKun
-- 0.2.1     2016-02-14   removed dynamic sql code                        FKun
-- 0.2.0     2015-02-26   added revert_transaction procedure              FKun
-- 0.1.0     2014-11-26   initial commit                                  FKun
--

/**********************************************************
* C-o-n-t-e-n-t:
*
* FUNCTIONS:
*   recover_audit_version(aid BIGINT, changes JSONB, table_op INTEGER, table_name TEXT, 
*     schema_name TEXT DEFAULT 'public', merge_with_table_version INTEGER DEFAULT 0) RETURNS SETOF VOID
*   revert_distinct_transaction(tid BIGINT) RETURNS SETOF VOID
*   revert_disticnt_transactions(start_from_tid BIGINT, end_at_tid BIGINT) RETURNS SETOF VOID
*   revert_transaction(tid BIGINT) RETURNS SETOF VOID
*   revert_transactions(start_from_tid BIGINT, end_at_tid BIGINT) RETURNS SETOF VOID
***********************************************************/

/**********************************************************
* RECOVER
*
* Procedure to apply DML operations recovered from the logs
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.recover_audit_version(
  aid BIGINT, 
  changes JSONB,
  table_op INTEGER,
  table_name TEXT,
  schema_name TEXT DEFAULT 'public',
  merge_with_table_version INTEGER DEFAULT 0
  ) RETURNS SETOF VOID AS
$$
DECLARE
  table_version JSONB;
  diff JSONB;
  update_stmt TEXT;
  delimiter TEXT;
  column_name TEXT;
BEGIN
  -- INSERT case
  IF table_op = 1 THEN
    BEGIN
      EXECUTE format(
        'DELETE FROM %I.%I WHERE audit_id = $1',
        schema_name, table_name) 
        USING aid;

      -- row is already deleted
      EXCEPTION
        WHEN no_data_found THEN
          NULL;
    END;

  -- UPDATE case
  ELSIF table_op = 2 THEN
	IF merge_with_table_version <> 0 THEN
      changes := pgmemento.generate_log_entry(tid, aid, table_name, schema_name);

      -- get recent version of that row
      EXECUTE format(
        'SELECT row_to_json(*)::jsonb FROM %I.%I WHERE audit_id = $1',
        schema_name, table_name)
        INTO table_version USING aid;

      -- create diff between the two versions
      SELECT INTO diff COALESCE(
        (SELECT ('{' || string_agg(to_json(key) || ':' || value, ',') || '}') 
           FROM jsonb_each(table_version)
             WHERE NOT ('{' || to_json(key) || ':' || value || '}')::jsonb <@ changes
        ),'{}')::jsonb AS delta;
    ELSE
      diff := changes;
    END IF;

    -- update the row with values from diff
    IF diff IS NOT NULL AND diff <> '{}'::jsonb THEN
      -- set variables for update statement
      delimiter := '';
      update_stmt := format('UPDATE %I.%I SET', schema_name, table_name);

      -- loop over found keys
      FOR column_name IN SELECT jsonb_object_keys(diff) LOOP
        update_stmt := update_stmt || delimiter ||
                         format(' %I = (SELECT %I FROM jsonb_populate_record(null::%I.%I, $1))',
                         column_name, column_name, schema_name, table_name);
        delimiter := ',';
      END LOOP;

      -- add condition and execute
      update_stmt := update_stmt || ' WHERE audit_id = $2';
      EXECUTE update_stmt USING diff, aid;
    END IF;

  -- DELETE and TRUNCATE case
  ELSE
    BEGIN
      EXECUTE format(
        'INSERT INTO %I.%I SELECT * FROM jsonb_populate_record(null::%I.%I, $1)',
         schema_name, table_name, schema_name, table_name)
         USING changes;

      -- row has already been re-inserted, so update it based on the values of this deleted version
      EXCEPTION
        WHEN unique_violation THEN
          -- merge changes with recent version of table record and update row
          PERFORM pgmemento.recover_audit_version(aid, changes, 2, table_name, schema_name, 1);
    END;
  END IF;
END;
$$
LANGUAGE plpgsql;


/**********************************************************
* REVERT TRANSACTION
*
* Procedures to revert a single transaction or a range of
* transactions. All table operations are processed in 
* reversed order so no foreign keys should be violated. 
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.revert_transaction(tid BIGINT) RETURNS SETOF VOID AS
$$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN 
    SELECT r.audit_order, r.audit_id, r.changes, 
           a.schema_name, a.table_name, e.op_id
      FROM pgmemento.table_event_log e
      JOIN pgmemento.audit_table_log a ON a.relid = e.table_relid
      JOIN pgmemento.transaction_log t ON t.txid = e.transaction_id
      JOIN LATERAL (
        SELECT 
          CASE WHEN e.op_id > 2 THEN
            rank() OVER (ORDER BY audit_id ASC)
          ELSE
            rank() OVER (ORDER BY audit_id DESC)
          END AS audit_order,
          audit_id, changes 
        FROM pgmemento.row_log 
          WHERE event_id = e.id
      ) r ON (true)
      WHERE upper(a.txid_range) IS NULL
        AND t.txid = tid
        ORDER BY e.id DESC, audit_order ASC
  LOOP
    PERFORM pgmemento.recover_audit_version(rec.audit_id, rec.changes, rec.op_id, rec.table_name, rec.schema_name, 0);
  END LOOP;
END;
$$ 
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmemento.revert_transactions(
  start_from_tid BIGINT, 
  end_at_tid BIGINT
  ) RETURNS SETOF VOID AS
$$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT r.audit_order, r.audit_id, r.changes, 
           a.schema_name, a.table_name, e.op_id
      FROM pgmemento.table_event_log e
      JOIN pgmemento.audit_table_log a ON a.relid = e.table_relid
      JOIN pgmemento.transaction_log t ON t.txid = e.transaction_id
      JOIN LATERAL (
        SELECT 
          CASE WHEN e.op_id > 2 THEN
            rank() OVER (ORDER BY audit_id ASC)
          ELSE
            rank() OVER (ORDER BY audit_id DESC)
          END AS audit_order,
          audit_id, changes 
        FROM pgmemento.row_log 
          WHERE event_id = e.id
      ) r ON (true)
      WHERE upper(a.txid_range) IS NULL
        AND t.txid BETWEEN start_from_tid AND end_at_tid
        ORDER BY t.id DESC, e.id DESC, audit_order ASC
  LOOP
    PERFORM pgmemento.recover_audit_version(rec.audit_id, rec.changes, rec.op_id, rec.table_name, rec.schema_name, 0);
  END LOOP;
END;
$$ 
LANGUAGE plpgsql;


/**********************************************************
* REVERT DISTINCT TRANSACTION
*
* Procedures to revert a single transaction or a range of
* transactions. For each distinct audit_it only the oldest 
* operation is applied to make the revert process faster.
* This will very likely not work for transaction affecting
* multiple tables referenced by foreign keys. Execute only 
* for transactions done on tables without any references. 
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.revert_distinct_transaction(tid BIGINT) RETURNS SETOF VOID AS
$$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN 
    SELECT s.audit_id, s.op_id, s.changes, s.schema_name, s.table_name, s.audit_order
    FROM (
      SELECT DISTINCT ON (r.audit_id)
        r.audit_id, r.changes, r.event_id,
        a.schema_name, a.table_name, e.op_id,
        CASE WHEN e.op_id > 2 THEN
          rank() OVER (PARTITION BY r.event_id ORDER BY r.audit_id ASC)
        ELSE
          rank() OVER (PARTITION BY r.event_id ORDER BY r.audit_id DESC)
        END AS audit_order
      FROM pgmemento.row_log r
      JOIN pgmemento.table_event_log e ON e.id = r.event_id
      JOIN pgmemento.audit_table_log a ON a.relid = e.table_relid
      JOIN pgmemento.transaction_log t ON t.txid = e.transaction_id
        WHERE upper(a.txid_range) IS NULL
          AND t.txid = tid
          ORDER BY r.audit_id, e.id
    ) s
    ORDER BY s.event_id DESC, s.audit_order ASC 
  LOOP
    PERFORM pgmemento.recover_audit_version(rec.audit_id, rec.changes, rec.op_id, rec.table_name, rec.schema_name, 1);
  END LOOP;
END;
$$ 
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmemento.revert_distinct_transactions(
  start_from_tid BIGINT, 
  end_at_tid BIGINT
  ) RETURNS SETOF VOID AS
$$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN 
    SELECT s.audit_id, s.op_id, s.changes, s.schema_name, s.table_name, s.audit_order
    FROM (
      SELECT DISTINCT ON (r.audit_id)
        r.audit_id, r.changes, r.event_id,
        a.schema_name, a.table_name, e.op_id, t.id,
        CASE WHEN e.op_id > 2 THEN
          rank() OVER (PARTITION BY r.event_id ORDER BY r.audit_id ASC)
        ELSE
          rank() OVER (PARTITION BY r.event_id ORDER BY r.audit_id DESC)
        END AS audit_order
      FROM pgmemento.row_log r
      JOIN pgmemento.table_event_log e ON e.id = r.event_id
      JOIN pgmemento.audit_table_log a ON a.relid = e.table_relid
      JOIN pgmemento.transaction_log t ON t.txid = e.transaction_id
        WHERE upper(a.txid_range) IS NULL
          AND t.txid BETWEEN start_from_tid AND end_at_tid
          ORDER BY r.audit_id, t.id, e.id
    ) s
    ORDER BY s.id DESC, s.event_id DESC, s.audit_order ASC 
  LOOP
    PERFORM pgmemento.recover_audit_version(rec.audit_id, rec.changes, rec.op_id, rec.table_name, rec.schema_name, 1);
  END LOOP;
END;
$$ 
LANGUAGE plpgsql;