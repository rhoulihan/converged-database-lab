-- S4, one canonical form, two documents.
-- Stonebraker and Pavlo (section 2.3, p.23): "if the join is not one-to-many,
-- then there will be duplicated data", and of document databases, "there is no
-- data independence".
--
-- One normalized canonical form (customers, orders, order lines) is projected as
-- two different documents by two duality views:
--   m08s4_cust_dv : customer-centric. A customer with its orders[] (each with lines[]).
--   m08s4_ord_dv  : order-centric. An order with its lines[] and a nested
--                   customer {custId, name}, read-only in this view.
-- The customer-centric view is created before the data is loaded, the
-- order-centric one after it: adding a second shape over stored data is one view
-- definition, not a data migration.
-- Customer 1 has 5 orders. Its name is changed once, through the customer-centric
-- view. Every one of its 5 order documents, read through the order-centric view,
-- shows the new name at once: no sync job, no fan-out update, because the name is
-- stored in one column of one row. Orders and lines hold no name column at all.
-- This is a correctness demonstration, not a measurement: no meter is used.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08s4_check;
drop procedure if exists m08s4_fingerprint;
drop view if exists m08s4_ord_dv;
drop view if exists m08s4_cust_dv;
drop table if exists m08s4_line purge;
drop table if exists m08s4_ord purge;
drop table if exists m08s4_cust purge;
delete from m08_metrics where name like 's4-%' or name like 'tmp:s4-%';

-- ===== Canonical form: three normalized tables =====
-- Child tables are keyed by a field the document carries (ordId, lineId). The
-- parent keys (cust_id, ord_id) are plain NOT NULL columns, never selected in
-- the nested part of a view.
create table m08s4_cust (
  cust_id number constraint m08s4_cust_pk primary key,
  name    varchar2(40) not null
);

create table m08s4_ord (
  ord_id  number constraint m08s4_ord_pk primary key,
  cust_id number not null constraint m08s4_ord_cust_fk references m08s4_cust,
  status  varchar2(12) not null,
  total   number not null
);

create index m08s4_ord_cust_ix on m08s4_ord (cust_id);

create table m08s4_line (
  line_id number constraint m08s4_line_pk primary key,
  ord_id  number not null constraint m08s4_line_ord_fk references m08s4_ord,
  sku     varchar2(20) not null,
  qty     number not null
);

create index m08s4_line_ord_ix on m08s4_line (ord_id);

-- ===== Projection 1: customer-centric document =====
create json relational duality view m08s4_cust_dv as
select json {'_id'    : c.cust_id,
             'name'   : c.name,
             'orders' : [ select json {'ordId'  : o.ord_id,
                                       'status' : o.status,
                                       'total'  : o.total,
                                       'lines'  : [ select json {'lineId' : l.line_id,
                                                                 'sku'    : l.sku,
                                                                 'qty'    : l.qty}
                                                      from m08s4_line l with insert update delete
                                                     where l.ord_id = o.ord_id ]}
                            from m08s4_ord o with insert update delete
                           where o.cust_id = c.cust_id ]}
  from m08s4_cust c with insert update delete;

-- ===== Data =====
-- 3 customers. Customer 1 has orders 1 to 5, customer 2 has orders 6 to 8,
-- customer 3 has none. Every order has 2 lines.
insert into m08s4_cust (cust_id, name)
  select level, 'Customer ' || level from dual connect by level <= 3;

insert into m08s4_ord (ord_id, cust_id, status, total)
  select level, case when level <= 5 then 1 else 2 end, 'OPEN', level * 10
    from dual connect by level <= 8;

insert into m08s4_line (line_id, ord_id, sku, qty)
  select level, ceil(level / 2), 'SKU-' || level, 1 from dual connect by level <= 16;

commit;

-- Fingerprint of the stored data before the second view exists: tables,
-- columns (system-generated ones included) and a hash of every row.
create or replace procedure m08s4_fingerprint(p_name varchar2) as
  t number; c number; h number;
begin
  select count(*) into t from user_tables where table_name like 'M08S4\_%' escape '\';
  select count(*) into c
    from user_tab_cols tc join user_tables ut on ut.table_name = tc.table_name
   where tc.table_name like 'M08S4\_%' escape '\';
  select (select nvl(sum(ora_hash(cust_id || '|' || name)), 0) from m08s4_cust)
       + (select nvl(sum(ora_hash(ord_id || '|' || cust_id || '|' || status || '|' || total)), 0) from m08s4_ord)
       + (select nvl(sum(ora_hash(line_id || '|' || ord_id || '|' || sku || '|' || qty)), 0) from m08s4_line)
    into h from dual;
  m08_meter.record('tmp:s4-fp-' || p_name || '-tables', t);
  m08_meter.record('tmp:s4-fp-' || p_name || '-cols', c);
  m08_meter.record('tmp:s4-fp-' || p_name || '-rows', h);
end;
/

begin
  m08s4_fingerprint('before');
end;
/

-- ===== Projection 2: order-centric document, added after the data =====
-- The orders are already stored and committed. Adding this second shape is one
-- view definition: no table is created or altered and no row is written, and
-- the view returns the existing orders at once (checked below).
-- The nested customer is read-only here: this view can show the name but not
-- change it. The customer-centric view owns that change.
create json relational duality view m08s4_ord_dv as
select json {'_id'      : o.ord_id,
             'status'   : o.status,
             'total'    : o.total,
             'customer' : ( select json {'custId' : c.cust_id,
                                         'name'   : c.name}
                              from m08s4_cust c with noinsert noupdate nodelete
                             where c.cust_id = o.cust_id ),
             'lines'    : [ select json {'lineId' : l.line_id,
                                         'sku'    : l.sku,
                                         'qty'    : l.qty}
                              from m08s4_line l with insert update delete
                             where l.ord_id = o.ord_id ]}
  from m08s4_ord o with insert update delete;

-- The new view returns the orders that were stored before it existed, and the
-- stored data did not change.
declare
  docs  number;
  lines number;
  names number;
  ok    number;
begin
  m08s4_fingerprint('after');
  select count(*),
         nvl(sum(json_value(d.data, '$.lines.size()' returning number)), 0),
         count(case when json_value(d.data, '$.customer.name') = c.name then 1 end)
    into docs, lines, names
    from m08s4_ord_dv d
    join m08s4_ord o on o.ord_id = d.data."_id".number()
    join m08s4_cust c on c.cust_id = o.cust_id;
  m08_meter.record('s4-order-view-docs-after-load', docs);
  m08_meter.record('tmp:s4-order-view-lines-after-load', lines);
  m08_meter.record('tmp:s4-order-view-names-after-load', names);
  select case when count(distinct p.name) = 3 and count(*) = 3 then 1 else 0 end
    into ok
    from (select substr(name, length('tmp:s4-fp-before-') + 1) name, value from m08_metrics
           where name like 'tmp:s4-fp-before-%') p
    join (select substr(name, length('tmp:s4-fp-after-') + 1) name, value from m08_metrics
           where name like 'tmp:s4-fp-after-%') a
      on a.name = p.name and a.value = p.value;
  m08_meter.record('tmp:s4-data-unchanged', ok);
end;
/

-- ===== Change once, read everywhere =====
create or replace procedure m08s4_check as
  c_new  constant varchar2(40) := 'Renamed Customer';
  ok     number;
  n      number;
  copies number := 0;
begin
  -- Before: all 5 order documents of customer 1 show the old name.
  select case when count(*) = 5
               and count(case when json_value(d.data, '$.customer.name') = 'Customer 1'
                              then 1 end) = 5
              then 1 else 0 end
    into ok
    from m08s4_ord_dv d where d.data.customer.custId.number() = 1;
  m08_meter.record('tmp:s4-before-old-name', ok);

  -- The two projections are different shapes. The order document has its own
  -- fields plus customer.name, and no orders array; the customer document has
  -- an orders array of 5, and no nested customer.
  select case when count(*) = 1 then 1 else 0 end
    into ok
    from m08s4_ord_dv d
   where d.data."_id" = 1
     and json_exists(d.data, '$.status') and json_exists(d.data, '$.total')
     and json_exists(d.data, '$.lines') and json_exists(d.data, '$.customer.custId')
     and json_exists(d.data, '$.customer.name')
     and not json_exists(d.data, '$.orders') and not json_exists(d.data, '$.name');
  select case when count(*) = 1 and ok = 1 then 1 else 0 end
    into ok
    from m08s4_cust_dv d
   where d.data."_id" = 1
     and json_value(d.data, '$.name') = 'Customer 1'
     and json_value(d.data, '$.orders.size()' returning number) = 5
     and not json_exists(d.data, '$.customer');
  m08_meter.record('tmp:s4-shapes', ok);

  -- The one change: customer 1's name, through the customer-centric view.
  update m08s4_cust_dv d
     set d.data = json_transform(d.data, set '$.name' = c_new)
   where d.data."_id" = 1;
  m08_meter.record('s4-docs-updated', sql%rowcount);

  -- After: every order document of customer 1 shows the new name.
  select count(case when json_value(d.data, '$.customer.name') = c_new then 1 end)
    into n
    from m08s4_ord_dv d where d.data.customer.custId.number() = 1;
  m08_meter.record('s4-order-docs-showing-new-name', n);

  -- Exactly one customer row changed, and only customer 1 has the new name.
  select case when count(case when name = c_new then 1 end) = 1
               and count(case when name = c_new and cust_id = 1 then 1 end) = 1
               and count(case when name = 'Customer 1' then 1 end) = 0
               and count(case when name like 'Customer _' then 1 end) = 2
              then 1 else 0 end
    into ok from m08s4_cust;
  m08_meter.record('tmp:s4-one-row', ok);

  -- Stored copies of the new name: scan every text and JSON column of every
  -- S4 table, system-generated columns included.
  for col in (select tc.table_name, tc.column_name, tc.data_type
                from user_tab_cols tc join user_tables t on t.table_name = tc.table_name
               where tc.table_name like 'M08S4\_%' escape '\'
                 and tc.data_type in ('VARCHAR2', 'NVARCHAR2', 'CHAR', 'NCHAR', 'CLOB',
                                      'NCLOB', 'JSON', 'BLOB')) loop
    if col.data_type in ('JSON', 'BLOB') then
      execute immediate 'select count(*) from ' || col.table_name ||
                        ' where instr(json_serialize("' || col.column_name ||
                        '" returning clob), :1) > 0'
        into n using '"' || c_new || '"';
    elsif col.data_type in ('CLOB', 'NCLOB') then
      execute immediate 'select count(*) from ' || col.table_name ||
                        ' where instr("' || col.column_name || '", :1) > 0'
        into n using c_new;
    else
      execute immediate 'select count(*) from ' || col.table_name ||
                        ' where "' || col.column_name || '" = :1'
        into n using c_new;
    end if;
    copies := copies + n;
  end loop;
  m08_meter.record('s4-name-copies', copies);

  -- Orders and lines have no name column at all.
  select count(*) into n
    from user_tab_cols
   where table_name in ('M08S4_ORD', 'M08S4_LINE') and column_name like '%NAME%';
  m08_meter.record('tmp:s4-no-name-column', case when n = 0 then 1 else 0 end);

  -- The order-centric view cannot change the name: the dictionary says the
  -- customer table is read-only in it, and an attempt is refused.
  select count(*) into n
    from user_json_duality_view_tabs
   where view_name = 'M08S4_ORD_DV' and table_name = 'M08S4_CUST'
     and allow_insert = 'NO' and allow_update = 'NO' and allow_delete = 'NO';
  ok := 0;
  begin
    update m08s4_ord_dv d
       set d.data = json_transform(d.data, set '$.customer.name' = 'Not Allowed')
     where d.data."_id" = 1;
  exception
    when others then ok := 1;
  end;
  select case when n = 1 and ok = 1 and count(*) = 0 then 1 else 0 end
    into ok from m08s4_cust where name = 'Not Allowed';
  m08_meter.record('tmp:s4-readonly-in-order-view', ok);
end;
/

begin
  m08s4_check;
end;
/

-- ===== Measurements (as METRIC rows) =====
select 'METRIC:' || name || ':' || to_char(value, 'FM999999990')
  from m08_metrics
 where name like 's4-%'
 order by name;

-- ===== Assertions (read back from m08_metrics) =====

-- One update through the customer view changed one document and one row.
select 'ASSERT:s4-one-row-changed:' ||
       case when (select value from m08_metrics where name = 's4-docs-updated') = 1
             and (select value from m08_metrics where name = 'tmp:s4-one-row') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- All 5 order documents showed the old name before, and show the new name after.
select 'ASSERT:s4-order-view-reflects:' ||
       case when (select value from m08_metrics where name = 'tmp:s4-before-old-name') = 1
             and (select value from m08_metrics where name = 's4-order-docs-showing-new-name') = 5
            then 'PASS' else 'FAIL' end
  from dual;

-- The new name is stored exactly once, and orders and lines have no name column.
select 'ASSERT:s4-no-copies:' ||
       case when (select value from m08_metrics where name = 's4-name-copies') = 1
             and (select value from m08_metrics where name = 'tmp:s4-no-name-column') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- The two projections are different shapes.
select 'ASSERT:s4-order-view-shape:' ||
       case when (select value from m08_metrics where name = 'tmp:s4-shapes') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- The order-centric view, created after the load, returns all 8 stored orders
-- with their 16 lines and the right customer names, and creating it changed no
-- table, column or row.
select 'ASSERT:s4-second-view-after-load:' ||
       case when (select value from m08_metrics where name = 's4-order-view-docs-after-load') = 8
             and (select value from m08_metrics where name = 'tmp:s4-order-view-lines-after-load') = 16
             and (select value from m08_metrics where name = 'tmp:s4-order-view-names-after-load') = 8
             and (select value from m08_metrics where name = 'tmp:s4-data-unchanged') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- The nested customer is read-only in the order-centric view.
select 'ASSERT:s4-order-view-customer-readonly:' ||
       case when (select value from m08_metrics where name = 'tmp:s4-readonly-in-order-view') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 's4-%' or name like 'tmp:s4-%';

drop procedure if exists m08s4_check;
drop procedure if exists m08s4_fingerprint;
drop view if exists m08s4_ord_dv;
drop view if exists m08s4_cust_dv;
drop table if exists m08s4_line purge;
drop table if exists m08s4_ord purge;
drop table if exists m08s4_cust purge;

select 'ASSERT:s4-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08S4\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 's4-%' or name like 'tmp:s4-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
