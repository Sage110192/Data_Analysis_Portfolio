-- 【删库】
DROP DATABASE Supply_Chain;

-- 【建库】：供应链数据库
CREATE DATABASE Supply_Chain;
USE Supply_Chain;

-- 【维表部分】
-- 1.品类维表
CREATE TABLE dim_category(
	category_id INT PRIMARY KEY AUTO_INCREMENT COMMENT '类目ID',
    category_name VARCHAR(30) COMMENT '类目名称',
    category_code INT COMMENT '类目编码',
	parent_id INT COMMENT '父品类ID；一级类目填 0 或者 null',
    category_level INT COMMENT '类目级别',
    full_path_name VARCHAR(100) COMMENT '完整类目路径 `饮料 / 饮用水 / 瓶装矿泉水`',
    full_path_id VARCHAR(100) COMMENT 'ID 路径 `0,101,10103`',
	sort_no INT COMMENT '类目排序号',
    start_date DATE COMMENT '生效时间',
    end_date DATE COMMENT '作废时间',
    is_valid INT COMMENT '品类状态：0-作废 1-正常'
);

-- 2.供应商维表
CREATE TABLE dim_supplier(
	supplier_id INT PRIMARY KEY COMMENT '供应商ID',
	supplier_name VARCHAR(50) COMMENT '供应商名称',
    region VARCHAR(50) COMMENT '供应商地址',
    max_capacity INT COMMENT '最大产能（件）',
    quality_level CHAR COMMENT '质量等级',
    cooperation_status INT COMMENT '合作状态 0-停止，1-合作'
);

-- 3.仓库维表
CREATE TABLE dim_warehouse(
	warehouse_id INT PRIMARY KEY COMMENT '仓库ID',
	warehouse_name VARCHAR(50) COMMENT '仓库名称',
    warehouse_type VARCHAR(30) COMMENT '仓库类型：RDC 区域仓 / DC 分拨中心 / 前置仓 Front‑warehouse',
    region VARCHAR(20) COMMENT '大区（华东/华南/华北仓等，做看板分组用）',
    address VARCHAR(50) COMMENT '仓库地址',
    warehouse_status INT COMMENT '状态：1-正常、0-停用、2-维修'
);

-- 4.商品维表
CREATE TABLE dim_sku(
	sku_id INT PRIMARY KEY COMMENT '主键，SKU唯一标识',
	sku_name VARCHAR(20) COMMENT '商品名称',
	sku_code INT COMMENT '商品编码，业务唯一键',
	brand_id INT COMMENT '品牌',
	category_l1_id INT COMMENT '一级分类',
	category_l2_id INT COMMENT '二级分类',
	category_l3_id INT COMMENT '三级分类',
	spec VARCHAR(20) COMMENT '规格描述（如500ml*12瓶）',
	unit VARCHAR(10) COMMENT '计量单位（箱、瓶、个）',
	unit_cost DECIMAL(10, 2) COMMENT '单位成本',
	supplier_id INT COMMENT '供应商ID，关联dim_supplier',
	shelf_life_days INT COMMENT '保质期天数',
	is_perishable INT COMMENT '是否效期敏感品（1=是, 0=否）',
	sku_status INT COMMENT '商品状态：1-正常，0-停产，2-新品',
	created_time DATETIME COMMENT '记录创建时间',
	updated_time DATETIME COMMENT '最后更新时间',
	etl_time DATETIME COMMENT 'ETL 导入时间，生产审计字段',
	dt DATE COMMENT '分区，如 dt=2026‑08‑23',
    -- 外键
    FOREIGN KEY(supplier_id) REFERENCES dim_supplier(supplier_id)
);

-- 5.补货规则（安全库存、提前期等）
CREATE TABLE dim_sku_replenishment_rule(
	sku_id INT COMMENT 'SKU ID',
	warehouse_id INT COMMENT '仓库 ID（若规则按仓配置）',
	lead_time_days INT COMMENT '供应商提前期（天），从下单到入库的平均天数',
	review_cycle_days INT COMMENT '补货周期（天），两次补货之间的间隔天数',
	safety_stock_qty INT COMMENT '安全库存数量（防止波动的缓冲库存）',
	target_days_of_supply INT COMMENT '目标供应天数（目标库存可支撑的销售天数）',
	min_order_qty INT COMMENT '最小起订量（供应商要求）',
	max_order_qty INT COMMENT '单次最大补货量（防止过度补货）',
	max_stock_qty INT COMMENT '最大库存/目标库存上限',
	rounding_qty INT COMMENT '补货取整单位（如箱规：12）',
	target_stock_qty INT COMMENT '目标库存水位',
	lead_time_buffer_days INT COMMENT '缓冲天数（应对波动）',
	service_level DECIMAL(5,4) COMMENT '服务水平（如0.95），用于安全库存计算参考',
	demand_days INT COMMENT '需求观测天数 (默认 30 天，可配置)',
	avg_daily_sales_qty DECIMAL(18,4) COMMENT '系统维护的日均销量',
	replenishment_model VARCHAR(20) COMMENT '补货模型：MIN-MAX/ROP/PERIODIC/JIT',
	reorder_point_qty INT COMMENT '补货触发点（ROP）',
	forecast_version VARCHAR(20) COMMENT '关联的需求预测版本号（大厂通常接算法forecast）',
	health_days_low DECIMAL(18,2) COMMENT '健康阈值‑库存偏低可售天数',
	health_days_high DECIMAL(18,2) COMMENT '健康阈值‑超储起始可售天数',
	is_active INT COMMENT '是否启用：1-启用，0-停用',
	effective_start_date DATE COMMENT '规则生效开始日期',
	effective_end_date DATE COMMENT '规则生效结束日期（默认9999-12-31）',
	etl_time DATETIME COMMENT '数据加载时间',
    -- 主键
    PRIMARY KEY(sku_id, warehouse_id),
    FOREIGN KEY(sku_id) REFERENCES dim_sku(sku_id),
    FOREIGN KEY(warehouse_id) REFERENCES dim_warehouse(warehouse_id)
);

-- 【DWD明细层】
--  6.实时库存快照
CREATE TABLE dwd_inventory_snapshot(
	snapshot_id INT PRIMARY KEY COMMENT '主键，快照记录ID（自增/雪花）',
	snapshot_time DATETIME COMMENT '快照时间戳',
	sku_id INT COMMENT 'SKU ID',
	warehouse_id INT COMMENT '仓库 ID',
	on_hand_qty INT COMMENT '实物库存数量（在库总数）',
	locked_qty INT COMMENT '锁定库存数量（已下单未出库等）',
	available_qty INT COMMENT '可用库存数量 = on_hand_qty - locked_qty',
	in_transit_qty INT COMMENT '在途库存数量',
	reserved_qty INT COMMENT '预留库存',
	damaged_qty INT COMMENT '破损数量',
	frozen_qty INT COMMENT '冻结数量',
	data_source VARCHAR(20) COMMENT '快照来源（如oms、wms、手工调整）',
	etl_time DATETIME COMMENT '数据加载时间',
	dt DATE COMMENT '分区字段，格式yyyyMMdd',
    -- 外键
    FOREIGN KEY(sku_id) REFERENCES dim_sku(sku_id),
    FOREIGN KEY(warehouse_id) REFERENCES dim_warehouse(warehouse_id)
);


-- 【DWS汇总层】
--  7.库存日照
CREATE TABLE dws_fact_inventory(
	dt DATE COMMENT '分区字段，业务日期yyyyMMdd',
	sku_id INT COMMENT 'SKU ID',
	warehouse_id INT COMMENT '仓库 ID',
	begin_on_hand_qty INT COMMENT '期初实物库存',
	begin_locked_qty INT COMMENT '期初锁定库存',
	begin_available_qty INT COMMENT '期初可用库存',
	end_on_hand_qty INT COMMENT '期末实物库存',
	end_locked_qty INT COMMENT '期末锁定库存',
	end_available_qty INT COMMENT '期末可用库存',
	defect_qty INT COMMENT '不良品库存',
	in_transit_qty INT COMMENT '期末在仓在途/待上架',
	max_onhand_qty INT COMMENT '当日最高库存',
	min_onhand_qty INT COMMENT '当日最低库存',
	avg_on_hand_qty INT COMMENT '日均实物库存（可由更细粒度快照计算，也可用期初期末平均）',
	avg_available_qty INT COMMENT '日均可用库存',
	inventory_cost_amt DECIMAL(18, 4) COMMENT '期末库存金额（成本价*库存数量）',
	turnover_days INT COMMENT '库存周转天数',
	stock_age_days INT COMMENT '平均库龄',
	etl_time DATETIME COMMENT '数据加载时间',
    -- 主键
    PRIMARY KEY(dt, sku_id, warehouse_id),
    FOREIGN KEY(sku_id) REFERENCES dim_sku(sku_id),
    FOREIGN KEY(warehouse_id) REFERENCES dim_warehouse(warehouse_id)
);

-- 8.商品每日销量
CREATE TABLE dws_act_sales_daily(
	dt DATE COMMENT '分区字段，业务日期yyyyMMdd',
	sku_id INT COMMENT 'SKU ID',
	channel_id INT COMMENT '渠道ID',
	warehouse_id INT COMMENT '仓库 ID（发货仓）',
	sales_qty INT COMMENT '销售数量',
	sales_amt DECIMAL(18, 4) COMMENT '销售额',
	return_qty INT COMMENT '退货数量（用于分析退货率，不影响有效销量）',
	return_amt DECIMAL(18, 4) COMMENT '退货金额',
	net_sales_qty INT COMMENT '有效销售数量（已剔除取消、退货、刷单等）',
	net_sales_amt DECIMAL(18, 4) COMMENT '有效销售额（含税或不含税，需统一口径）',
	order_count INT COMMENT '有效订单数',
	shipment_qty INT COMMENT '实际出库数量',
	avg_price DECIMAL(18, 4) COMMENT '成交均价',
	is_promotion INT COMMENT '是否促销（1=是, 0=否，快消品关键）',
	promo_out_qty INT COMMENT '促销出库量',
	exclude_cal_flag INT COMMENT '是否参与日均销量计算：1 正常纳入、0 剔除 (异常 / 一次性订单)',
	etl_time DATETIME COMMENT '数据加载时间',
    -- 主键
    PRIMARY KEY(dt, sku_id, warehouse_id, channel_id),
    FOREIGN KEY(sku_id) REFERENCES dim_sku(sku_id),
    FOREIGN KEY(warehouse_id) REFERENCES dim_warehouse(warehouse_id)
);

--  9.采购在途事实表
CREATE TABLE dws_fact_po_onway(
	dt DATE COMMENT '分区字段，快照日期yyyyMMdd',
	po_id INT COMMENT '采购单号',
	po_line_id INT COMMENT '采购单行号',
	sku_id INT COMMENT 'SKU ID',
	warehouse_id INT COMMENT '目标仓库 ID',
	supplier_id INT COMMENT '供应商 ID',
	po_date DATE COMMENT '采购下单日期',
	po_qty INT COMMENT '采购数量',
	received_qty INT COMMENT '已到货数量',
	onway_qty INT COMMENT '在途数量 = po_qty − received_qty',
	expect_arrive_date DATE COMMENT '预计到货日期 yyyy‑MM‑dd',
	expected_arrive_qty_7d INT COMMENT '未来7天内预计到货数量',
	expected_arrive_qty_30d INT COMMENT '未来30天内预计到货数量',
	earliest_expected_date DATE COMMENT '最早预计到货日期',
	latest_expected_date DATE COMMENT '最晚预计到货日期',
	actual_arrival_date DATE COMMENT '实际到货日',
	lead_time_days INT COMMENT '供应商标准交期',
	create_dt DATE COMMENT 'PO 创建日期',
	unit_price DECIMAL(18,4) COMMENT '采购单价',
	po_amt DECIMAL(18,4) COMMENT '采购金额',
	po_status INT COMMENT 'PO 状态：待到货 / 部分入库 / 已完成 / 已取消 / 已作废',
	is_valid_onway INT COMMENT '有效在途标记：1 计入补货供应、0 不计入 (取消 / 作废单)',
	etl_time DATETIME COMMENT '数据加载时间',
    -- 主键
    PRIMARY KEY(po_id, po_line_id),
    FOREIGN KEY(sku_id) REFERENCES dim_sku(sku_id),
    FOREIGN KEY(warehouse_id) REFERENCES dim_warehouse(warehouse_id),
    FOREIGN KEY(supplier_id) REFERENCES dim_supplier(supplier_id)
);
-- 10.项目管理表
CREATE TABLE project_management (
project_id INT PRIMARY KEY COMMENT '项目ID',
project_name VARCHAR(200) COMMENT '项目名称',
start_date DATE COMMENT '项目开启日期',
deadline DATE COMMENT '项目预期结束日期',
project_level INT COMMENT '项目重要星级：1-5星',
first_per_name VARCHAR(30) COMMENT '第一阶段名称',
first_per_owner VARCHAR(30) COMMENT '第一阶段总负责人',
fir_start_date DATE COMMENT '第一阶段开启日期',
fir_end_date DATE COMMENT '第一阶段结束日期',
fir_finish INT COMMENT '第一阶段完成标记',
second_per_name VARCHAR(30) COMMENT '第二阶段名称',
second_per_owner VARCHAR(30) COMMENT '第二阶段总负责人',
sec_start_date DATE COMMENT '第二阶段开启日期',
sec_end_date DATE COMMENT '第二阶段结束日期',
sec_finish INT COMMENT '第二阶段完成标记',
third_per_name VARCHAR(30) COMMENT '第三阶段名称',
third_per_owner VARCHAR(30) COMMENT '第三阶段总负责人',
thi_start_date DATE COMMENT '第三阶段开启日期',
thi_end_date DATE COMMENT '第三阶段结束日期',
thi_finish INT COMMENT '第三阶段完成标记',
four_per_name VARCHAR(30) COMMENT '第四阶段名称',
four_per_owner VARCHAR(30) COMMENT '第四阶段总负责人',
four_start_date DATE COMMENT '第四阶段开启日期',
four_end_date DATE COMMENT '第四阶段结束日期',
four_finish INT COMMENT '第四阶段完成标记',
five_per_name VARCHAR(30) COMMENT '第五阶段名称',
five_per_owner VARCHAR(30) COMMENT '第五阶段总负责人',
five_start_date DATE COMMENT '第五阶段开启日期',
five_end_date DATE COMMENT '第五阶段结束日期',
five_finish INT COMMENT '第五阶段完成标记',
is_finish INT COMMENT '项目完成标记',
end_date DATE COMMENT '项目实际完成日期'
);
