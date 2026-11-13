-- S3 at scale (B): check all four stages together, then drop every S3 (B)
-- object. The per-stage checks ran in 61, 64, 66 and 68; this one confirms
-- that all four stages were recorded, every one with a captured plan for every
-- statement, and that the six result hashes are the same at every stage.
-- Costs are reported as metrics only; nothing here compares them.

select 'ASSERT:s3b-all-stages-same-results:' ||
       case when count(*) = 4
             and count(distinct sig) = 1
             and count(sig) = 4
            then 'PASS' else 'FAIL' end
  from (select json_value(r.data, '$.stmts.byid.digest') || ':' ||
               json_value(r.data, '$.stmts.status.digest') || ':' ||
               json_value(r.data, '$.stmts."sku-hot".digest') || ':' ||
               json_value(r.data, '$.stmts."sku-rare".digest') || ':' ||
               json_value(r.data, '$.stmts."agg-status".digest') || ':' ||
               json_value(r.data, '$.stmts."agg-unwind".digest') sig
          from "m08b3_runs" r
         where json_value(r.data, '$.stmts.byid.digest') is not null
           and json_value(r.data, '$.stmts."agg-unwind".digest') is not null);

select 'ASSERT:s3b-all-stages-plans-captured:' ||
       case when count(*) = 4
             and count(distinct json_value(r.data, '$.stage' returning number)) = 4
             and sum(case when json_value(r.data, '$.plansOk') = 'true'
                           and json_value(r.data, '$.measuredOk') = 'true'
                          then 1 else 0 end) = 4
            then 'PASS' else 'FAIL' end
  from "m08b3_runs" r;

drop view if exists "m08b3_orders";
drop table if exists m08b3_lines purge;
drop table if exists m08b3_orders_t purge;
drop table if exists m08b3_orders_v0 purge;
drop table if exists "m08b3_orders" purge;
drop table if exists "m08b3_runs" purge;

select 'ASSERT:s3b-teardown-clean:' ||
       case when (select count(*) from user_objects
                   where upper(object_name) like 'M08B3\_%' escape '\') = 0
            then 'PASS' else 'FAIL' end
  from dual;
