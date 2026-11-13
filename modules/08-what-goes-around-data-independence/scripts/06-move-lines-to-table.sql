-- S3 stage 3: move the order lines out of the flex column into their own table.
-- Each line is keyed by the lineId the document already carries; order_id is
-- a plain foreign key column that the view joins on but does not select.

create table sales_order_lines (
  line_id  varchar2(36) primary key,
  order_id number not null references sales_orders_t,
  sku      varchar2(20),
  qty      number
);

-- Index the foreign key: the view reads an order's lines by order_id.
create index sales_order_lines_order_ix on sales_order_lines (order_id);

insert into sales_order_lines (line_id, order_id, sku, qty)
  select j.line_id, t.id, j.sku, j.qty
    from sales_orders_t t,
         json_table(t.data, '$.items[*]'
           columns (line_id varchar2(36) path '$.lineId',
                    sku     varchar2(20) path '$.sku',
                    qty     number       path '$.qty')) j;

update sales_orders_t t
   set t.data = json_transform(t.data, remove '$.items');

commit;

create or replace json relational duality view "sales_orders" as
  select json {'_id': t.id, 'customer': t.customer, 'status': t.status,
               'items': [select json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty} from sales_order_lines l with insert update delete where l.order_id = t.id],
               t.data as flex}
    from sales_orders_t t with insert update delete;

-- Every seeded line (counted in the untouched stage-0 table) is now a row.
select 'ASSERT:s3-stage3-lines:' ||
       case when (select count(*) from sales_order_lines) =
                 (select count(*) from sales_orders_v0 v,
                         json_table(v.data, '$.items[*]' columns (line_id path '$.lineId')) j)
             and (select count(*) from sales_orders_t t
                   where json_exists(t.data, '$.items')) = 0
            then 'PASS' else 'FAIL' end
  from dual;
