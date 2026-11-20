DROP TABLE IF EXISTS
    fact_returns, fact_sales, customer_rfm,
    dim_customer, dim_product, dim_country, dim_date,
    stg_sales, stg_returns, stg_orders, stg_rfm
CASCADE;

CREATE TABLE stg_sales (
	invoice text,
	stock_code text,
	description text,
	quantity int,
	invoice_date timestamp,
	price numeric(10,2),
	customer_id int,  -- empty in the csv = guest = null
	country text,
	is_guest boolean,
	total_price numeric, -- has float noise from pandas; we recalculate it later
	sale_date date,
	sale_year int,
	sale_month int,
	sale_year_month text,
	sale_weekday text,
	sale_hour int
);

select * from stg_sales;

Create table stg_returns (
	invoice text,
	stock_code text,
	description text,
	quantity int,
	invoice_date timestamp,
	price numeric(10,2),
	customer_id int,
	country text,
	is_guest boolean,
	total_price numeric,
	sale_date date,
	sale_year int,
	sale_month int,
	sale_year_month text,
	sale_weekday text,
	sale_hour int
);

select * from stg_returns;

create table stg_orders (
	invoice text,
	order_date timestamp,
	customer_d int,
	country text,
	items int,
	order_value numeric
);

select * from stg_orders;

create table stg_rfm (
	customer_id int,
	recency int,
	frequency int,
	monetary numeric,
	r_score int,
	f_score int,
	m_score int,
	segment text
);

-- Dimension Tables

create table dim_date (
	date_key date,
	year int,
	quarter int,
	month int,
	month_name text,
	year_month text,
	weekday_num int,
	weekday_name text,
	is_weekend boolean
);

create table dim_country (
	country_id INTEGER GENERATED ALWAYS AS IDENTITY,
	country_name text not null
);

create table dim_product (
	stock_code text,
	description text not null
);

create table dim_customer (
	customer_id int,
	first_purchase_date date, -- used for cohort analysis
	last_purchase_date date
);

-- ---------------------------------------------------------------------
-- FACT TABLES
-- Country lives on the fact table (not on dim_customer) because guest
-- sales have a country but no customer, and a few customers appear
-- under more than one country.
-- ---------------------------------------------------------------------

create table fact_sales (
	sales_id bigint generated always as identity,
	invoice varchar(10) not null,
	invoice_ts timestamp not null,
	date_key date not null,
	stock_code text not null,
	customer_id int, -- null = guest
	country_id int not null,
	quantity int not null check (quantity > 0),
	unit_price numeric(10,2) not null check (unit_price > 0),
	total_price numeric(12,2) not null
);


create table fact_returns (
	return_id bigint generated always as identity,
	invoice varchar(10) not null,
	invoice_ts timestamp not null,
	date_key date not null,
	stock_code text not null,
	customer_id int,
	country_id int not null,
	quantity int not null check (quantity < 0),
	unit_price numeric(10,2) not null check (unit_price > 0),
	total_price numeric(12,2) not null -- negative for returns
);

-- ---------------------------------------------------------------------
-- RFM TABLE (loaded from Python's rfm.csv)
-- ---------------------------------------------------------------------

CREATE TABLE customer_rfm (
    customer_id INTEGER,
    recency     INTEGER,
    frequency   INTEGER,
    monetary    NUMERIC(12,2),
    r_score     INTEGER,
    f_score     INTEGER,
    m_score     INTEGER,
    segment     TEXT
);

select
	count(*) as row_count
from stg_sales;

SELECT 'stg_sales'   AS table_name, COUNT(*) AS row_count FROM stg_sales
UNION ALL SELECT 'stg_returns', COUNT(*) FROM stg_returns
UNION ALL SELECT 'stg_orders',  COUNT(*) FROM stg_orders
UNION ALL SELECT 'stg_rfm',     COUNT(*) FROM stg_rfm;

-- 1) dim_date: one row per calendar day, covering whole calendar years 
-- (Power BI time intelligence funtions need a complete calendar)

Insert into dim_date
select d::date,
	extract(year from d)::int,
	extract(quarter from d)::int,
	extract(month from d)::int,
	to_char(d, 'FMMonth'),
	to_char(d, 'YYYY-MM'),
	extract(ISODOW from d)::int,
	to_char(d, 'FMDay'),
	extract(ISODOW from d) in (6, 7)
from generate_series(
	(select date_trunc('year', min(sale_date)) from stg_sales),
	(select date_trunc('year', max(sale_date)) + interval '1 year - 1 day' from stg_sales),
	interval '1 day'
) as d;


-- 2) dim_country: every country found in sales OR returns

insert into dim_country (country_name)
select country from stg_sales
union
select country from stg_returns
order by 1;

-- 3) dim_product: one description per stock code.
-- 212 stock codes have more than one description in the raw data, so we
-- keep the most frequent one (alphabetical order breaks ties)
-- sales and returns are combined because some returned products
-- never appear in the sales table.

insert into dim_product (stock_code, description)
select stock_code, description
from (
		select stock_code, description,
			row_number() over (partition by stock_code
								order by count(*) desc, description) as rn
		from (select stock_code, description from stg_sales
			union all
			select stock_code, description from stg_returns) as all_lines
		group by stock_code, description
) as ranked
where rn = 1;


-- 4) dim_customer: known customers only (guests have no ID).
-- so 28 customers only appear in returns, then they will get null purchase dates.

insert into dim_customer (customer_id, first_purchase_date, last_purchase_date)
select c.customer_id, s.first_purchase, s.last_purchase
from (select customer_id from stg_sales where customer_id is not null
	union
	select customer_id from stg_returns where customer_id is not null) as c
left join (select customer_id,
					min(sale_date) as first_purchase,
					max(sale_date) as last_purchase
			from stg_sales
			where customer_id is not null
			group by customer_id) as s
		on s.customer_id = c.customer_id;


-- 5) fact tables. total_price is recalculayed and rounded to remove the
-- floating-point noise pandas added (eg 15.299999999).

insert into fact_sales
	(invoice, invoice_ts, date_key, stock_code, customer_id, country_id,
	quantity, unit_price, total_price)
select s.invoice, s.invoice_date, s.invoice_date::date, s.stock_code,
		s.customer_id, c.country_id, s.quantity, s.price,
		round(s.quantity * s.price, 2)
from stg_sales s
join dim_country c on c.country_name = s.country
order by s.invoice_date, s.invoice;

insert into fact_returns
	(invoice, invoice_ts, date_key, stock_code, customer_id, country_id,
	quantity, unit_price, total_price)
select s.invoice, s.invoice_date, s.invoice_date::date, s.stock_code,
		s.customer_id, c.country_id, s.quantity, s.price,
		round(s.quantity * s.price, 2)
from stg_returns s
join dim_country c on c.country_name = s.country
order by s.invoice_date, s.invoice;

-- 6) RFM table from python

insert into customer_rfm
select customer_id, recency, frequency, ROUND(monetary, 2),
		r_score, f_score, m_score, segment
from stg_rfm;

--7) Primary keys (each row is uniquely identified)

alter table dim_date add primary key (date_key);
alter table dim_country add primary key (country_id),
						add constraint uq_country_name unique (country_name);
alter table dim_product add primary key (stock_code);
alter table dim_customer add primary key (customer_id);
alter table fact_sales add primary key (sales_id);
alter table fact_returns add primary key (return_id);
alter table customer_rfm add primary key (customer_id);

-- 8) Foreign keys ( a fact row can only point to a dimension row that exists)
-- customer_id may be null (guest sales), which foreign keys allow

alter table fact_sales
	add constraint fk_sales_date foreign key (date_key)
	references dim_date (date_key),
	add constraint fk_sales_product foreign key (stock_code)
	references dim_product (stock_code),
	add constraint fk_sales_customer foreign key (customer_id)
	references dim_customer (customer_id),
	add constraint fk_sales_country foreign key (country_id)
	references dim_country (country_id);

alter table fact_returns
	add constraint fk_returns_date foreign key (date_key)
	references dim_date (date_key),
	add constraint fk_returns_product foreign key (stock_code)
	references dim_product (stock_code),
	add constraint fk_returns_customer foreign key (customer_id)
	references dim_customer (customer_id),
	add constraint fk_returns_country foreign key (country_id)
	references dim_country (country_id);

-- 9) Indexs (make joins and filters on big tables fast)

create index idx_sales_date on fact_sales (date_key);
create index idx_sales_customer on fact_sales (customer_id);
create index idx_sales_product on fact_sales (stock_code);
create index idx_sales_country on fact_sales (country_id);
create index idx_sales_invoice on fact_sales (invoice);

create index idx_returns_date on fact_returns (date_key);
create index idx_returns_customer on fact_returns (customer_id);
create index idx_returns_product on fact_returns (stock_code);

commit;

analyze; -- refresh statistics so the query planner picks good plans

-- Validations: every line should say ok

with checks as (
	select 'fact_sales rows match staging' as check_name,
		(select count(*) from fact_sales)::numeric as actual,
		(select count(*) from stg_sales)::numeric as expected
	union all
	select 'fact_returns rows match staging',
		(select count(*) from fact_returns), (select count(*) from stg_returns)
	union all
	select 'revenue matches staging (whole pounds)',
		(select round(sum(total_price), 0) from fact_sales),
		(select round(sum(total_price), 0) from stg_sales)
	union all
	select 'order count matches python order.csv',
		(select count(distinct invoice) from fact_sales),
		(select count(*) from stg_orders)
	union all
	select 'customers in RFM = known customers with sales',
		(select count(*) from customer_rfm),
		(select count(distinct customer_id) from fact_sales)
	union all
	select 'guest rows kept (customer_id is null)',
		(select count(*) from fact_sales where customer_id is null),
		(select count(*) from stg_sales where is_guest)
)
select check_name, actual, expected,
	case when actual = expected then 'OK' else 'CHECK' end as status
from checks;