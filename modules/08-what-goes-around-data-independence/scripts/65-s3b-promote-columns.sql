-- S3 at scale (B), stage 2: promote customer and status out of the JSON
-- column into real columns, as S3 stage 2 does. The view maps them by name;
-- the app sees no change. No API restart: this is a view-to-view change.
--
-- Stage-2 indexes: a B-tree on the status column. The stage-1 index on the
-- JSON status value is dropped, because status is no longer in the JSON. The
-- multivalue index on data.items[*].sku stays: the items are still there.

drop index m08b3_t_status_jx;

alter table m08b3_orders_t add (customer varchar2(40), status varchar2(20));

update m08b3_orders_t t
   set t.customer = json_value(t.data, '$.customer'),
       t.status   = json_value(t.data, '$.status'),
       t.data     = json_transform(t.data, remove '$.customer', remove '$.status');

commit;

create index m08b3_t_status_ix on m08b3_orders_t (status);

begin
  dbms_stats.gather_table_stats(user, 'M08B3_ORDERS_T', cascade => true);
end;
/

create or replace json relational duality view "m08b3_orders" as
  select json {'_id': t.id, 'customer': t.customer, 'status': t.status, t.data as flex}
    from m08b3_orders_t t with insert update delete;

select 'ASSERT:s3b-stage2-columns:' ||
       case when (select count(*) from m08b3_orders_t) = 20000
             and (select count(*) from m08b3_orders_t
                   where customer is null or status is null) = 0
             and (select count(*) from m08b3_orders_t t
                   where json_exists(t.data, '$.customer')
                      or json_exists(t.data, '$.status')) = 0
            then 'PASS' else 'FAIL' end
  from dual;
