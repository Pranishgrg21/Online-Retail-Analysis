-- 04 analysis_queries.sql
-- Table used fact_sales, fact_returns, dim_date, dim_product, dim_country, dim_customer,
-- customer_rfm

-- Q1 Headline KPIs


select round(sum(total_price), 0) as total_revenue,
	count(distinct invoice) as total_orders,
	round(sum(total_price) / count(distinct invoice), 2) as avg_order_value,
	count(distinct customer_id) as unique_customers,
	count(distinct stock_code) as unique_products
from fact_sales;

-- Q2 Monthly revenue with month-over-month growth (Date_trunc + lag)
-- note: December 2011 only has data up to 9 december, so its drop is not real.

with monthly as (
	select date_trunc('month', invoice_ts)::date as month,
			sum(total_price) as revenue
	from fact_sales
	group by 1
)
select month,
		round(revenue, 2) as revenue,
		round(lag(revenue) over w, 2) as previous_month,
		round((revenue - lag(revenue) over w)
				/ lag(revenue) over w * 100, 1) as mon_growth_pct
from monthly
window w as (order by month)
order by month;

-- Q3 Running (cumulative) revenue (sum over)

with monthly as( 
	select date_trunc('month', invoice_ts)::date as month,
			sum(total_price) as revenue
	from fact_sales
	group by 1
) 
select month,
		round(revenue, 2) as revenue,
		round(sum(revenue) over (order by month), 2) as running_total
from monthly
order by month;

-- Q4a) Top 10 products by revenue (RANK)

select rank() over (order by sum(f.total_price) desc) as revenue_rank,
		p.stock_code,
		p.description,
		sum(f.quantity) as unit_sold,
		round(sum(f.total_price), 2) as revenue
from fact_sales f
join dim_product p on p.stock_code = f.stock_code
group by p.stock_code, p.description
order by revenue desc
limit 10;

--Q4b) top 3 products in each month (row_number + partition by)

with product_month as (
	select d.year_month, p.stock_code, p.description,
			sum(f.total_price) as revenue
	from fact_sales f
	join dim_date d on d.date_key = f.date_key
	join dim_product p on p.stock_code = f.stock_code
	group by d.year_month, p.stock_code, p.description
),
ranked as (
		select *,
				row_number() over (partition by year_month order by revenue desc) as rn
		from product_month
)
select year_month, rn as position, description, round(revenue, 2) as revenue
from ranked
where rn <= 3
order by year_month, rn;

-- Q5a) Revenue by country with share of total
-- sum(sum()) over () gives the grand total for the percentage

select c.country_name,
		round(sum(f.total_price), 2) as revenue,
		round(100 * sum(f.total_price) / sum(sum(f.total_price)) over (), 1) as share_pct
from fact_sales f
join dim_country c on c.country_id = f.country_id
group by c.country_name
order by revenue desc
limit 10;

-- Q5b) International picture without the UK (share of non-UK revenue)

select c.country_name,
		round(sum(f.total_price), 2) as revenue,
		round(100 * sum(f.total_price) / sum(sum(f.total_price)) over (), 1) as share_of_non_uk_pct
from fact_sales f
join dim_country c on c.country_id = f.country_id
where c.country_name <> 'United Kingdom'
group by c.country_name
order by revenue desc
limit 10;


-- Q6a) Order value: mean vs median (one row per invoice first)

with orders as (
	select invoice, sum(total_price) as order_value
	from fact_sales
	group by invoice
)
select count(*) as orders,
		round(avg(order_value), 2) as mean_order_value,
		round(percentile_cont(0.5) within group (order by order_value)::numeric, 2) as median_order_value,
		round(max(order_value), 2) as largest_order
from orders;

-- Q6b) Repeat customer rate (known customer only)

with customer_orders as (
	select customer_id, count(distinct invoice) as orders
	from fact_sales
	where customer_id is not null
	group by customer_id
)
select count(*) as customers,
		count(*) filter (where orders > 1) as repeat_customers,
		round(100.0 * count(*) filter (where orders > 1) / count(*), 1) as repeat_rate_pct,
		round(avg(orders), 2) as avg_orders_per_customer
from customer_orders;


-- Q6c) Known customers vs guests: this explains why rfm revenue (~8.5M)
-- is less than total revenue (~10.0M)

select case when customer_id is null then 
					'Guest (no customer ID)' 
				else 'Known customer' end as customer_type,
				count(distinct invoice) as orders,
				round(sum(total_price), 2) as revenue,
				round(100 * sum(total_price) / sum(sum(total_price)) over (), 1) as share_pct
from fact_sales
group by 1
order by revenue desc;

-- Q7a) Revenue by weekday (note: there are no Saturday sales in this date)

select d.weekday_num, d.weekday_name,
		count(distinct f.invoice) as orders,
		round(sum(f.total_price), 2) as revenue
from fact_sales f
join dim_date d on d.date_key = f.date_key
group by d.weekday_num, d.weekday_name
order by d.weekday_num;

-- Q7b) Revenue by hour of day

select extract(Hour from invoice_ts)::int as hour,
		count(distinct invoice) as orders,
		round(sum(total_price), 2) as revenue
from fact_sales
group by 1
order by 1;

-- Q8. RFM scoring done in SQL with NTILE(5), then compared with python
-- NTILE cuts customers into 5 equal-sized groups.
-- small difference vs python are expected: Python's qcut keeps
-- customers with the same value in the same group, NTILE does not.


with snapshot as (
	-- "today" = one day after the last purchase by a known customer
	select max(invoice_ts) + interval '1 day' as snapshot_ts
	from fact_sales
	where customer_id is not null
),
base as (
	select f.customer_id,
			extract(day from (s.snapshot_ts - MAX(f.invoice_ts)))::int as recency,
			count(distinct f.invoice) as frequency,
			sum(f.total_price) as monetary
	from fact_sales f
	cross join snapshot s
	where f.customer_id is not null
	group by f.customer_id, s.snapshot_ts
),
scored as (
	select customer_id, recency, frequency, monetary,
			NTILE(5) over (order by recency desc) as r_score, -- fewer days = better
			NTILE(5) over (order by frequency, customer_id) as f_score,
			NTILE(5) over (order by monetary) as m_score
	from base
),
segmented as (
	select *,
			case when r_score >= 4 and f_score >= 4 then 'champions'
				 when r_score >= 3 and f_score >= 3 then 'Loyal'
				 when r_score >= 4 and f_score <= 2 then 'New / Recent'
				 when r_score <= 2 and f_score >= 3 then 'At Risk'
				 when r_score <= 2 and f_score <= 2 then 'Lost'
				 else 'Regular' end as segment
	from scored
)
select sg.segment as sql_segment,
		count(*) as customer_sql,
		count(*) filter (where r.segment = sg.segment) as same_as_python,
		round(100.0 * count(*) filter (where r.segment = sg.segment) / count(*), 1) as match_pct
from segmented sg
join customer_rfm r on r.customer_id = sg.customer_id
group by sg.segment
order by customer_sql desc;