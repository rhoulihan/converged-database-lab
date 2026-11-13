-- S3 stage 2: promote customer and status out of the flex column into real
-- relational columns. The view now maps them by name; the app sees no change.

alter table sales_orders_t add (customer varchar2(40), status varchar2(20));

update sales_orders_t t
   set t.customer = json_value(t.data, '$.customer'),
       t.status   = json_value(t.data, '$.status'),
       t.data     = json_transform(t.data, remove '$.customer', remove '$.status');

commit;

create or replace json relational duality view "sales_orders" as
  select json {'_id': t.id, 'customer': t.customer, 'status': t.status, t.data as flex}
    from sales_orders_t t with insert update delete;

select 'ASSERT:s3-stage2-columns:' ||
       case when (select count(*) from sales_orders_t) = 8
             and (select count(*) from sales_orders_t
                   where customer is null or status is null) = 0
             and (select count(*) from sales_orders_t t
                   where json_exists(t.data, '$.customer')
                      or json_exists(t.data, '$.status')) = 0
            then 'PASS' else 'FAIL' end
  from dual;
