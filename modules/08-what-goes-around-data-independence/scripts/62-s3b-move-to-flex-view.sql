-- S3 at scale (B), stage 1: the same move as S3 stage 1, on m08b3_orders.
-- The collection's documents move into a table with one JSON column (the whole
-- document minus _id), and a duality view with the collection's name goes in
-- front of it. The app sees the same documents.
--
-- Stage-1 indexes: the stage-0 indexes rebuilt on the new table's JSON column,
-- a multivalue index on data.items[*].sku and an index on the status value.
-- That is what a DBA carries over when the data moves. Whether the generated
-- SQL against the view can use them is what the plans in 64 show.

alter table "m08b3_orders" rename to m08b3_orders_v0;

create table m08b3_orders_t (
  id   number primary key,
  data json(object)
);

insert into m08b3_orders_t (id, data)
  select json_value(v.data, '$._id' returning number),
         json_transform(v.data, remove '$._id')
    from m08b3_orders_v0 v;

commit;

create multivalue index m08b3_t_sku_mvi on m08b3_orders_t t (t.data.items[*].sku.string());

create index m08b3_t_status_jx on m08b3_orders_t (json_value(data, '$.status'));

begin
  dbms_stats.gather_table_stats(user, 'M08B3_ORDERS_T', method_opt => 'FOR ALL COLUMNS SIZE AUTO FOR ALL INDEXED COLUMNS SIZE 254', cascade => true, no_invalidate => false);
end;
/

create json relational duality view "m08b3_orders" as
  select json {'_id': t.id, t.data as flex} from m08b3_orders_t t with insert update delete;

select 'ASSERT:s3b-stage1-rows:' ||
       case when (select count(*) from "m08b3_orders") = 20000
             and (select count(*) from m08b3_orders_t) = 20000
            then 'PASS' else 'FAIL' end
  from dual;
