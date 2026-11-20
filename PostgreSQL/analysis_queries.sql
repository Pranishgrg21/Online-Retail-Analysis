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
	select date_trunc()
)