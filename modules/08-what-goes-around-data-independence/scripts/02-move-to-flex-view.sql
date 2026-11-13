-- S3 stage 1: move the collection's documents into a relational table and put a
-- duality view with the collection's name in front of it. The whole document
-- (minus _id) lives in one JSON flex column, so the app sees the same documents.

-- Keep the stage-0 collection table under another name.
alter table "sales_orders" rename to sales_orders_v0;

create table sales_orders_t (
  id   number primary key,
  data json(object)
);

-- Each document's _id becomes the key; the rest of the document goes into data.
insert into sales_orders_t (id, data)
  select json_value(v.data, '$._id' returning number),
         json_transform(v.data, remove '$._id')
    from sales_orders_v0 v;

commit;

create json relational duality view "sales_orders" as
  select json {'_id': t.id, t.data as flex} from sales_orders_t t with insert update delete;

select 'ASSERT:s3-stage1-rows:' ||
       case when (select count(*) from "sales_orders") = 8
             and (select count(*) from sales_orders_t) = 8
            then 'PASS' else 'FAIL' end
  from dual;
