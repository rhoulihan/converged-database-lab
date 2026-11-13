-- S3 teardown: remove every S3 object so the next validator run starts clean.
-- IF EXISTS makes this safe whichever stage a previous run stopped at.

drop view if exists "sales_orders";
drop table if exists sales_order_lines purge;
drop table if exists sales_orders_t purge;
drop table if exists sales_orders_v0 purge;
drop table if exists "sales_orders" purge;
drop table if exists "probe_runs" purge;
drop synonym if exists sales_orders;
drop synonym if exists probe_runs;

select 'ASSERT:s3-teardown-clean:' ||
       case when (select count(*) from user_objects
                   where upper(object_name) like 'SALES\_%' escape '\'
                      or upper(object_name) = 'PROBE_RUNS') = 0
            then 'PASS' else 'FAIL' end
  from dual;
