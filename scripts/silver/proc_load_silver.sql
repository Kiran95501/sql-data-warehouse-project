/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Purpose:
    This stored procedure performs the ETL (Extract, Transform, Load) process to 
    populate the 'silver' schema tables from the 'bronze' schema.
	Actions Performed:
		- Truncates Silver tables.
		- Inserts transformed and cleansed data from Bronze into Silver tables.
		
Parameters:
    None. 
	  This stored procedure does not accept any parameters or return any values.

Usage Example:
    EXEC Silver.load_silver;
===============================================================================
*/


create or alter procedure silver.load_silver as
begin
	declare @start_time datetime, @end_time datetime, @batch_start_time datetime, @batch_end_time datetime;
	begin try
		set @batch_start_time = GETDATE();
		print '========================================================================';
		print 'Loading Silver Layer';
		print '========================================================================';


		print '------------------------------------------------------------------------';
		print 'Loading CRM Tables';
		print '------------------------------------------------------------------------';

		set @start_time = GETDATE();
		print '>> Truncating Table: silver.crm_cust_info';
		truncate table silver.crm_cust_info;

		print '>> Inserting Data Into: silver.crm_cust_info';
		insert into silver.crm_cust_info (
			cst_id,
			cst_key,
			cst_firstname,
			cst_lastname,
			cst_marital_status,
			cst_gndr,
			cst_create_date)

		select 
			cst_id,
			cst_key,
			trim(cst_firstname) as cst_firstname,
			trim(cst_lastname) as cst_lastname,
			CASE WHEN upper(trim(cst_marital_status)) = 'S' then 'Single'
				 WHEN upper(trim(cst_marital_status)) = 'M' then 'Married'
				 ELSE 'n/a'
			END cst_marital_status, -- Normalize marital status values to readable format

			CASE WHEN upper(trim(cst_gndr)) = 'F' then 'Female'
				 WHEN upper(trim(cst_gndr)) = 'M' then 'Male'
				 ELSE 'n/a'
			END cst_gndr, -- Normalize gender values to readable format
			cst_create_date
		from (
			select
			*,
			ROW_NUMBER() over(partition by cst_id order by cst_create_date desc) as flag_last
			from  bronze.crm_cust_info
			where cst_id is not null
		) t where flag_last = 1; -- Select the most recent records per customer
		set @end_time = GETDATE();
		print '>> Load Duration: ' + cast (datediff(second, @start_time, @end_time) as nvarchar) + ' Seconds';
		print '--------------------------------------------------------------';

		set @start_time = GETDATE();
		print '>> Truncating Table: silver.crm_prd_info';
		truncate table silver.crm_prd_info;

		print '>> Inserting Data Into: silver.crm_prd_info';
		insert into silver.crm_prd_info (
			prd_id,
			cat_id,
			prd_key,
			prd_nm,
			prd_cost,
			prd_line,
			prd_start_dt,
			prd_end_dt

		)
		select
			prd_id,
			replace(SUBSTRING(prd_key, 1, 5), '-', '_') as cat_id, -- Extract Category ID
			SUBSTRING(prd_key, 7, len(prd_key)) as prd_key, -- Extract Product Key
			prd_nm,
			isnull(prd_cost, 0) as prd_cost,
			case when UPPER(TRIM(prd_line)) = 'M' then 'Mountain'
				 when UPPER(TRIM(prd_line)) = 'R' then 'Road'
				 when UPPER(TRIM(prd_line)) = 'S' then 'Other Sales'
				 when UPPER(TRIM(prd_line)) = 'T' then 'Touring'
				 else 'n/a'
			end as prd_line, -- Map Product line code to descriptive values
			cast(prd_start_dt as date) as prd_start_dt,
			cast(
				lead(prd_start_dt) over(partition by prd_key order by prd_start_dt)-1 
				as date) as prd_end_dt -- Cal. end date as one day before the next start date
		from bronze.crm_prd_info;
		set @end_time = GETDATE();
		print '>> Load Duration: ' + cast (datediff(second, @start_time, @end_time) as nvarchar) + ' Seconds';
		print '--------------------------------------------------------------';

		set @start_time = GETDATE();
		print '>> Truncating Table: silver.crm_sales_details';
		truncate table silver.crm_sales_details;

		print '>> Inserting Data Into: silver.crm_sales_details';
		insert into silver.crm_sales_details (
			sls_ord_num,
			sls_prd_key,
			sls_cust_id,
			sls_order_dt,
			sls_ship_dt,
			sls_due_dt,
			sls_sales,
			sls_quantity,
			sls_price
		)
		select
		sls_ord_num,
		sls_prd_key,
		sls_cust_id,
		case
			when sls_order_dt = 0 or len(sls_order_dt) != 8 then NULL
			else cast(cast(sls_order_dt as varchar) as date)
		end as sls_order_dt,
		case
			when sls_ship_dt = 0 or len(sls_ship_dt) != 8 then NULL
			else cast(cast(sls_ship_dt as varchar) as date)
		end as sls_ship_dt,
		case
			when sls_due_dt = 0 or len(sls_due_dt) != 8 then NULL
			else cast(cast(sls_due_dt as varchar) as date)
		end as sls_due_dt,
		case when sls_sales is null or sls_sales <= 0 or sls_sales != sls_quantity * abs(sls_price)
					then sls_quantity * abs(sls_price)
				else sls_sales -- Recalculate sales if original value is missing or incorrect
		end sls_sales,
		sls_quantity,
		case when sls_price is null or sls_price <=0
				  then sls_sales / nullif(sls_quantity, 0)
			else sls_price -- Derive price if original value is invalid
		end as sls_price
		from bronze.crm_sales_details;
		set @end_time = GETDATE();
		print '>> Load Duration: ' + cast (datediff(second, @start_time, @end_time) as nvarchar) + ' Seconds';
		print '--------------------------------------------------------------'


		print '------------------------------------------------------------------------';
		print 'Loading ERP Tables';
		print '------------------------------------------------------------------------';

		set @start_time = GETDATE();
		print '>> Truncating Table: silver.erp_cust_az12';
		truncate table silver.erp_cust_az12;

		print '>> Inserting Data Into: silver.erp_cust_az12';
		insert into silver.erp_cust_az12 (cid, bdate, gen)
		select
			case when cid like 'NAS%' then SUBSTRING(cid, 4, LEN(cid)) -- Remove 'NAS' prefix in present
					else cid
			end cid,
			case when bdate > GETDATE () then null
				else bdate -- Set future birth dates to null
			end as bdate,
			case when upper(trim(gen)) in ('F', 'FEMALE') then 'Female'
				when upper(trim(gen)) in ('M', 'MALE') then 'Male'
				else 'n/a'
			end as gen -- Normalize gender values and handle unknown cases
		from bronze.erp_cust_az12;
		set @end_time = GETDATE();
		print '>> Load Duration: ' + cast (datediff(second, @start_time, @end_time) as nvarchar) + ' Seconds';
		print '--------------------------------------------------------------';

		set @start_time = GETDATE();
		print '>> Truncating Table: silver.erp_loc_a101';
		truncate table silver.erp_loc_a101;

		print '>> Inserting Data Into: silver.erp_loc_a101';
		insert into silver.erp_loc_a101 (cid, cntry)
		select
		REPLACE(cid, '-','') as cid,
		case when TRIM(cntry) = 'DE' then 'Germany'
			when TRIM(cntry) in ('US', 'USA') then 'United States'
			when TRIM(cntry) = '' or cntry is null then 'n/a'
			else TRIM(cntry)
		end as cntry -- Normalize and Handle missing or blank country codes
		from bronze.erp_loc_a101;
		set @end_time = GETDATE();
		print '>> Load Duration: ' + cast (datediff(second, @start_time, @end_time) as nvarchar) + ' Seconds';
		print '--------------------------------------------------------------';


		set @start_time = GETDATE();
		print '>> Truncating Table: silver.erp_px_cat_g1v2';
		truncate table silver.erp_px_cat_g1v2;

		print '>> Inserting Data Into: silver.erp_px_cat_g1v2';
		insert into silver.erp_px_cat_g1v2 (id, cat, subcat, maintenance)
		select 
		id,
		cat,
		subcat,
		maintenance
		from bronze.erp_px_cat_g1v2;
		set @end_time = GETDATE();
		print '>> Load Duration: ' + cast (datediff(second, @start_time, @end_time) as nvarchar) + ' Seconds';
		print '--------------------------------------------------------------';

		set @batch_end_time = GETDATE();
		print'==============================================================';
		print 'Loading Silver Layer is Completed';
		print '>> Total Load Duration: ' + cast (datediff(second, @batch_start_time, @batch_end_time) as nvarchar) + ' Seconds';
		print '=============================================================';
	end try
	begin catch
		print '============================================================================';
		print 'ERROR OCCURED DURING LOADING Silver LAYER';
		print 'Error Message' + Error_Message();
		print 'Error Message' + cast (Error_Number() as NVARCHAR);
		print 'Error Message' + cast (Error_State() as NVARCHAR);
		print '============================================================================'
	end catch
end
