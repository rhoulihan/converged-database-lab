-- S3 at scale (B), stage 3: move the order lines out of the JSON column into
-- their own table, as S3 stage 3 does. Each line is keyed by the lineId the
-- document already carries; order_id is a plain NOT NULL foreign key that the
-- view joins on but does not select. No API restart (view to view).
--
-- The lines are loaded by one INSERT ... SELECT, so each order's lines land
-- next to each other: what a one-time migration produces, and the friendly
-- layout for the view's join (S1 measures the interleaved layout too).
--
-- Stage-3 indexes: the foreign key index on order_id (the view reads an
-- order's lines by it) and a B-tree on sku. The multivalue index on
-- data.items[*].sku is dropped, because the items are no longer in the JSON.

create table m08b3_lines (
  line_id  varchar2(36) primary key,
  order_id number not null references m08b3_orders_t,
  sku      varchar2(20),
  qty      number
);

insert into m08b3_lines (line_id, order_id, sku, qty)
  select j.line_id, t.id, j.sku, j.qty
    from m08b3_orders_t t,
         json_table(t.data, '$.items[*]'
           columns (line_id varchar2(36) path '$.lineId',
                    sku     varchar2(20) path '$.sku',
                    qty     number       path '$.qty')) j;

drop index m08b3_t_sku_mvi;

update m08b3_orders_t t
   set t.data = json_transform(t.data, remove '$.items');

commit;

create index m08b3_lines_order_ix on m08b3_lines (order_id);

create index m08b3_lines_sku_ix on m08b3_lines (sku);

begin
  dbms_stats.gather_table_stats(user, 'M08B3_ORDERS_T', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08B3_LINES', cascade => true);
end;
/

create or replace json relational duality view "m08b3_orders" as
  select json {'_id': t.id, 'customer': t.customer, 'status': t.status,
               'items': [select json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty} from m08b3_lines l with insert update delete where l.order_id = t.id],
               t.data as flex}
    from m08b3_orders_t t with insert update delete;

select 'ASSERT:s3b-stage3-lines:' ||
       case when (select count(*) from m08b3_lines) =
                 (select count(*) from m08b3_orders_v0 v,
                         json_table(v.data, '$.items[*]' columns (line_id path '$.lineId')) j)
             and (select count(*) from m08b3_orders_t t
                   where json_exists(t.data, '$.items')) = 0
            then 'PASS' else 'FAIL' end
  from dual;
