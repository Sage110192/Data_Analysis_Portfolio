-- 【供应链SKU健康度&补货建议仪表盘】
USE Supply_Chain;
-- 1. 【SKU健康度&补货建议】
-- 1.1 现下库存量（库存实时快照表）
WITH available_qty AS(
	SELECT
		invs1.sku_id,
        invs1.warehouse_id,
        invs1.on_hand_qty - invs1.locked_qty - invs1.frozen_qty AS avl_qty
    FROM dwd_inventory_snapshot invs1
    WHERE invs1.dt = CURRENT_DATE()
        -- 假设：批次快照表（一批次所有 SKU 同一时刻刷新）
        AND invs1.snapshot_time = (SELECT MAX(invs2.snapshot_time) FROM dwd_inventory_snapshot invs2 WHERE invs2.sku_id = invs1.sku_id AND invs2.warehouse_id = invs1.warehouse_id )
),
-- 1.2 sku需求目标天数等参数（补货规则表）
sku_rules AS(
	SELECT
		r1.sku_id,
        r1.warehouse_id,
        r1.demand_days,
        r1.safety_stock_qty,
        r1.lead_time_days,
        r1.lead_time_buffer_days,
        r1.min_order_qty, 
        r1.target_days_of_supply,
        r1.max_stock_qty
    FROM dim_sku_replenishment_rule r1
    WHERE r1.is_active = 1
		AND r1.etl_time = (SELECT MAX(r2.etl_time) FROM dim_sku_replenishment_rule r2 WHERE r2.is_active = 1)
        AND r1.demand_days IS NOT NULL
),
-- 1.3 日均销售（SKU销量日表）
avg_sales AS(
	SELECT
		ds.dt,
        ds.sku_id,
        ds.warehouse_id,
        sr.demand_days,
        CASE
			WHEN sr.demand_days = 30 THEN ROUND((SUM(ds.net_sales_qty) OVER(PARTITION BY ds.sku_id, ds.warehouse_id ORDER BY ds.dt RANGE BETWEEN INTERVAL 29 DAY PRECEDING AND CURRENT ROW))/30, 2)
            WHEN sr.demand_days = 7 THEN  ROUND((SUM(ds.net_sales_qty) OVER(PARTITION BY ds.sku_id, ds.warehouse_id ORDER BY ds.dt RANGE BETWEEN INTERVAL 6 DAY PRECEDING AND CURRENT ROW))/7, 2)
            WHEN sr.demand_days = 3 THEN  ROUND((SUM(ds.net_sales_qty) OVER(PARTITION BY ds.sku_id, ds.warehouse_id ORDER BY ds.dt RANGE BETWEEN INTERVAL 2 DAY PRECEDING AND CURRENT ROW))/3, 2)
		END AS sku_avg_sales
    FROM dws_act_sales_daily ds
    LEFT JOIN sku_rules sr ON ds.sku_id = sr.sku_id AND ds.warehouse_id = sr.warehouse_id
    WHERE ds.dt >= DATE_ADD(DATE_ADD(current_date(), INTERVAL -1 DAY),  INTERVAL -30 DAY) 
		AND ds.dt <= DATE_ADD(current_date(),  INTERVAL -1 DAY) 
    	AND ds.is_promotion = 0
),
-- 1.4 健康度分级区间 —— 中间表
health_level AS (
SELECT
	aq.sku_id,
	aq.warehouse_id,
    aq.avl_qty,
    avgs.sku_avg_sales,
    sr.lead_time_days,
	sr.lead_time_buffer_days,
    sr.min_order_qty, 
	sr.target_days_of_supply,
	sr.max_stock_qty,
    -- 1.当下周转天数
    ROUND(aq.avl_qty / NULLIF(avgs.sku_avg_sales, 0) , 2) AS stock_avl_days,
    -- 2.库存健康度边界
    -- 安全库存
    sr.safety_stock_qty AS sku_stock_level1,
    -- ROP
    avgs.sku_avg_sales * (sr.lead_time_days + sr.lead_time_buffer_days) + sr.safety_stock_qty AS sku_stock_level2,
    -- ROP + 3 days缓冲期
    avgs.sku_avg_sales * (sr.lead_time_days + sr.lead_time_buffer_days + 3) + sr.safety_stock_qty AS sku_stock_level3,
    -- 最大值
    LEAST(avgs.sku_avg_sales * sr.target_days_of_supply + sr.safety_stock_qty, sr.max_stock_qty) AS sku_stock_level4
FROM available_qty aq
LEFT JOIN avg_sales avgs ON avgs.sku_id = aq.sku_id AND avgs.warehouse_id = aq.warehouse_id
	AND avgs.dt  = DATE_ADD(CURRENT_DATE, INTERVAL -1 DAY)
LEFT JOIN sku_rules sr ON sr.sku_id = aq.sku_id AND sr.warehouse_id = aq.warehouse_id
),
-- 1.5 SKU在途量（采购在途事实表）
c_onway_qty AS (
SELECT
	ow.sku_id,
    ow.warehouse_id,
    ow.supplier_id,
    ow.onway_qty,
    ow.expect_arrive_date
FROM dws_fact_po_onway ow
WHERE ow.dt  = CURRENT_DATE() 
),
-- 1.6 SKU销量分级 & 健康度
c_health_level AS (
SELECT
	hl.sku_id,
	hl.warehouse_id,
    hl.avl_qty,
    hl.stock_avl_days,
    hl.sku_avg_sales,
    hl.lead_time_days,
	hl.lead_time_buffer_days,
    hl.min_order_qty, 
	hl.target_days_of_supply,
	hl.max_stock_qty,
    -- 1.6.1 SKU分级（畅销品/滞销/正常）
    CASE 
		WHEN hl.sku_avg_sales >= 150 THEN '畅销品'
        WHEN hl.sku_avg_sales < 20 THEN '滞销品'
        ELSE '正常品'
	END AS `SKU销量分级`,
    -- 1.6.2 SKU健康度
    CASE 
		WHEN hl.avl_qty <= hl.sku_stock_level1  THEN '紧急补货预警'
        WHEN hl.avl_qty <= hl.sku_stock_level2 THEN '缺货预警'
        WHEN hl.avl_qty <= hl.sku_stock_level3 THEN '需关注'
        WHEN hl.avl_qty <= hl.sku_stock_level4 THEN '库存正常'
        ELSE '滞销预警'
	END AS `SKU健康度`
FROM health_level hl
WHERE hl.stock_avl_days IS NOT NULL
)
-- 1.7 SKU补货建议
SELECT
	chl.sku_id,
	chl.warehouse_id,
    s.sku_name,
    w.region,
    w.address,
    chl.`SKU销量分级`,
    chl.`SKU健康度`,
    -- 1.7.1 SKU优先级 
    CASE 
		-- 畅销品优先级
        WHEN chl.`SKU销量分级` = '畅销品' AND chl.`SKU健康度` = '紧急补货预警' THEN '最高优先级'
        WHEN chl.`SKU销量分级` = '畅销品' AND chl.`SKU健康度` = '缺货预警' THEN '第2优先级'
        WHEN chl.`SKU销量分级` = '畅销品' AND chl.`SKU健康度` = '需关注' THEN '第3优先级'
        WHEN chl.`SKU销量分级` = '畅销品' AND chl.`SKU健康度` = '滞销预警' THEN '第3优先级'
        -- 正常品优先级
        WHEN chl.`SKU销量分级` = '正常品' AND chl.`SKU健康度` = '紧急补货预警' THEN '最高优先级'
        WHEN chl.`SKU销量分级` = '正常品' AND chl.`SKU健康度` = '缺货预警' THEN '第2优先级'
        WHEN chl.`SKU销量分级` = '正常品' AND chl.`SKU健康度` = '需关注' THEN '第3优先级'
        WHEN chl.`SKU销量分级` = '正常品' AND chl.`SKU健康度` = '滞销预警' THEN '第3优先级'
        -- 滞销品优先级
        WHEN chl.`SKU销量分级` = '滞销品' AND chl.`SKU健康度` = '滞销预警' THEN '第2优先级'
        WHEN chl.`SKU销量分级` = '滞销品' AND chl.`SKU健康度` = '紧急补货预警' THEN '第2优先级'
        WHEN chl.`SKU销量分级` = '滞销品' AND chl.`SKU健康度` = '缺货预警' THEN '第3优先级'
		ELSE '正常运转'
	END AS `SKU补货优先级`,
    -- 1.7.2 补货建议量
	CASE
		WHEN ((chl.target_days_of_supply + chl.lead_time_days + chl.lead_time_buffer_days) * chl.sku_avg_sales - chl.avl_qty - IFNULL(ow.onway_qty, 0)) < chl.min_order_qty THEN chl.min_order_qty
        WHEN ((chl.target_days_of_supply + chl.lead_time_days + chl.lead_time_buffer_days) * chl.sku_avg_sales - chl.avl_qty - IFNULL(ow.onway_qty, 0)) > chl.max_stock_qty THEN chl.max_stock_qty
		ELSE (chl.target_days_of_supply + chl.lead_time_days + chl.lead_time_buffer_days) * chl.sku_avg_sales - chl.avl_qty - IFNULL(ow.onway_qty, 0)
	END AS Pur_adv_qty,
    chl.avl_qty,
    chl.stock_avl_days,
    chl.sku_avg_sales,
	chl.avl_qty,
    IFNULL(ow.onway_qty, 0) AS on_way_qty,
    di.turnover_days,
    di.stock_age_days
FROM c_health_level chl
LEFT JOIN c_onway_qty ow ON chl.sku_id = ow.sku_id AND chl.warehouse_id = ow.warehouse_id
LEFT JOIN dim_sku s ON s.sku_id = chl.sku_id
LEFT JOIN dim_warehouse w ON w.warehouse_id = chl.warehouse_id
LEFT JOIN dws_fact_inventory di ON chl.sku_id = di.sku_id AND chl.warehouse_id = di.warehouse_id
WHERE di.dt = DATE_ADD(CURRENT_DATE(), INTERVAL -1 DAY)
ORDER BY `SKU补货优先级`, chl.`SKU销量分级`, chl.`SKU健康度`
;


-- 2.【供应链SKU健康度总舱】
-- 2.1 仓库整体周转效率
SELECT
	t.warehouse_id,
    ROUND(SUM(invs1.on_hand_qty - invs1.locked_qty - invs1.frozen_qty)/warehouse_avg_sales, 1) AS warehouse_dos
FROM
	(
	SELECT
		ds.warehouse_id,
		ROUND(SUM(ds.net_sales_qty)/30, 2) AS warehouse_avg_sales
	FROM dws_act_sales_daily ds
	WHERE ds.dt >= DATE_ADD(DATE_ADD(current_date(), INTERVAL -1 DAY),  INTERVAL -30 DAY) 
		AND ds.dt <= DATE_ADD(current_date(),  INTERVAL -1 DAY) 
		AND ds.is_promotion = 0
	GROUP BY ds.warehouse_id
	)t
LEFT JOIN dwd_inventory_snapshot invs1 ON t.warehouse_id = invs1.warehouse_id
WHERE invs1.dt = CURRENT_DATE()
        AND invs1.snapshot_time = (SELECT MAX(invs2.snapshot_time) FROM dwd_inventory_snapshot invs2 WHERE invs2.sku_id = invs1.sku_id AND invs2.warehouse_id = invs1.warehouse_id )
GROUP BY t.warehouse_id
;

-- 2.2 仓库加权库龄
SELECT
	t2.warehouse_id,
    SUM(ac_stock_age_days) AS warehouse_stock_age_days
FROM
	(
	SELECT
		fi1.warehouse_id,
		fi1.sku_id,
		fi1.avg_available_qty/t.total_avg_available_qty * fi1.stock_age_days AS ac_stock_age_days
	FROM 
		(
		SELECT 
			warehouse_id,
			SUM(avg_available_qty) AS total_avg_available_qty
		FROM dws_fact_inventory
		GROUP BY warehouse_id
		)t
	LEFT JOIN dws_fact_inventory fi1 ON fi1.warehouse_id = t.warehouse_id AND fi1.dt = DATE_ADD(CURRENT_DATE(), INTERVAL -1 DAY)
    )t2
GROUP BY t2.warehouse_id
;

-- 【版本V1 说明】
-- 1.V1.0版本先以 过程指标 为总舱指标；V2.0版迭代到 核心 结果指标：（1）发货准确率（2）履约周期（3）单订单成本

-- 【版本V2 迭代计划】
-- 1.总舱核心指标迭代为结果指标：（1）发货准确率（2）履约周期（3）单订单成本
-- 2.健康度算法优化：由传统健康度算法---> 需求预测版SKU库存健康度
-- 3.仪表盘第三页：不同优先级业务场景对应的业务策略落地跟进