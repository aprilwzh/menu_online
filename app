import os
from datetime import datetime
from zoneinfo import ZoneInfo
from typing import List, Dict

import streamlit as st
import pandas as pd
from io import BytesIO
import zipfile
try:
    import qrcode
except ImportError:
    qrcode = None

from sqlalchemy import (
    create_engine, Column, Integer, String, Float, ForeignKey, DateTime, Text, Boolean
)
from sqlalchemy.orm import sessionmaker, declarative_base, relationship

# =============================
# 基础配置
# =============================
# 默认使用本地 SQLite；如需使用 PostgreSQL，设置环境变量：
#   export DATABASE_URL="postgresql+psycopg2://user:password@host:5432/yourdb"
def _env(name: str, default: str = "") -> str:
    """优先从环境变量读取；在 Streamlit Cloud 等平台也兼容 st.secrets."""
    val = os.getenv(name)
    if not val:
        try:
            val = st.secrets.get(name, default)  # type: ignore[attr-defined]
        except Exception:
            val = default
    return val

DATABASE_URL = _env("DATABASE_URL", "sqlite:///orders.db")
ADMIN_PASSWORD = _env("ADMIN_PASSWORD", "changeme")
TZ = ZoneInfo(_env("APP_TZ", "Asia/Tokyo"))
FRONTEND_URL = _env("FRONTEND_URL", "")  # 部署后的公开访问地址，用于生成二维码

# SQLite 需要关闭 check_same_thread
engine_kwargs = {"connect_args": {"check_same_thread": False}} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, echo=False, future=True, **engine_kwargs)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
Base = declarative_base()

# =============================
# 数据模型
# =============================
class MenuItem(Base):
    __tablename__ = "menu_items"
    id = Column(Integer, primary_key=True)
    name = Column(String(200), nullable=False)
    price = Column(Float, nullable=False)
    category = Column(String(100), nullable=False, default="主菜")
    description = Column(Text, default="")
    image_url = Column(Text, default="")
    is_available = Column(Boolean, default=True)

    order_items = relationship("OrderItem", back_populates="menu_item")


class Order(Base):
    __tablename__ = "orders"
    id = Column(Integer, primary_key=True)
    customer_name = Column(String(120), default="")
    table_no = Column(String(50), default="")
    contact = Column(String(120), default="")
    note = Column(Text, default="")
    status = Column(String(20), default="NEW")  # NEW, CONFIRMED, PREPARING, SERVED, CANCELLED
    total_price = Column(Float, default=0.0)
    channel = Column(String(50), default="onsite")
    source_ip = Column(String(64), default="")
    created_at = Column(DateTime, default=lambda: datetime.now(TZ))
    updated_at = Column(DateTime, default=lambda: datetime.now(TZ))

    items = relationship("OrderItem", back_populates="order", cascade="all, delete-orphan")


class OrderItem(Base):
    __tablename__ = "order_items"
    id = Column(Integer, primary_key=True)
    order_id = Column(Integer, ForeignKey("orders.id"), nullable=False)
    item_id = Column(Integer, ForeignKey("menu_items.id"), nullable=True)
    item_name = Column(String(200), nullable=False)
    unit_price = Column(Float, nullable=False)
    quantity = Column(Integer, nullable=False, default=1)

    order = relationship("Order", back_populates="items")
    menu_item = relationship("MenuItem", back_populates="order_items")


# =============================
# 初始化数据库 & 示例数据
# =============================
DEFAULT_MENU = [
    {"name": "招牌牛肉饭", "price": 28.0, "category": "主食", "description": "精选牛肉+米饭"},
    {"name": "鸡腿套餐", "price": 26.0, "category": "主食", "description": "炸鸡腿+小菜"},
    {"name": "青柠苏打", "price": 10.0, "category": "饮品", "description": "清爽解腻"},
    {"name": "美式咖啡", "price": 12.0, "category": "饮品", "description": "热/冰"},
    {"name": "薯条", "price": 9.0, "category": "小食", "description": "黄金脆薯"},
]


def init_db():
    Base.metadata.create_all(engine)
    db = SessionLocal()
    try:
        if db.query(MenuItem).count() == 0:
            for row in DEFAULT_MENU:
                db.add(MenuItem(**row))
            db.commit()
    finally:
        db.close()


# =============================
# 工具函数
# =============================

def get_db():
    return SessionLocal()


def format_currency(x: float) -> str:
    return f"¥{x:,.2f}" if x is not None else "¥0.00"


def ensure_cart():
    if "cart" not in st.session_state:
        st.session_state.cart = {}  # {menu_id: qty}


def cart_total(db) -> float:
    total = 0.0
    for mid, qty in st.session_state.cart.items():
        item = db.query(MenuItem).get(mid)
        if item and item.is_available:
            total += item.price * qty
    return total


def reset_cart():
    st.session_state.cart = {}


# =============================
# 界面：客户点单
# =============================

def page_order():
    st.header("🧾 客户点单")
    db = get_db()
    ensure_cart()

    # —— 从 URL 读取桌号参数 ?table=XXX，自动填入表单 ——
    table_param = ""
    try:
        # 新版 API
        qp = dict(st.query_params)
        if isinstance(qp.get("table"), list):
            table_param = qp.get("table", [""])[0]
        else:
            table_param = qp.get("table", "")
    except Exception:
        # 兼容老版本
        qp = st.experimental_get_query_params()
        table_param = qp.get("table", [""])[0] if isinstance(qp.get("table"), list) else qp.get("table", "")

    # 分类列表
    categories = [c[0] for c in db.query(MenuItem.category).distinct().all()]
    selected_cat = st.segmented_control("分类", options=["全部"] + categories, selection_mode="single")

    # 菜品卡片 + 搜索 + 布局模式
    search_kw = st.text_input("搜索菜名/描述", placeholder="例如：牛肉、咖啡")

    # 读取 URL 模式参数：?mode=list 或 ?mobile=1 则默认使用竖向列表（适配手机）
    layout_default = "grid"
    try:
        def _v(x):
            return str(x).lower() in ("1", "true", "list")
        if _v(qp.get("mode", "")) or _v(qp.get("mobile", "")):
            layout_default = "list"
    except Exception:
        pass
    use_list = st.toggle("移动端竖向列表模式", value=(layout_default=="list"))

    q = db.query(MenuItem).filter(MenuItem.is_available == True)
    if selected_cat and selected_cat != "全部":
        q = q.filter(MenuItem.category == selected_cat)
    if search_kw:
        like = f"%{search_kw}%"
        q = q.filter((MenuItem.name.ilike(like)) | (MenuItem.description.ilike(like)) | (MenuItem.category.ilike(like)))
    items = q.order_by(MenuItem.category, MenuItem.name).all()

    if use_list:
        # 竖向列表（更适配手机）
        for m in items:
            with st.container(border=True):
                if m.image_url:
                    st.image(m.image_url, use_container_width=True)
                st.subheader(m.name)
                st.caption(m.category)
                if m.description:
                    st.write(m.description)
                st.write(format_currency(m.price))
                qty_key = f"qty_{m.id}"
                default_qty = st.session_state.cart.get(m.id, 0)
                cols_li = st.columns([2,1])
                with cols_li[0]:
                    qty = st.number_input("数量", min_value=0, max_value=50, value=default_qty, step=1, key=qty_key)
                with cols_li[1]:
                    if st.button("加入购物车", key=f"add_{m.id}"):
                        if qty <= 0:
                            st.warning("数量需要大于 0")
                        else:
                            st.session_state.cart[m.id] = qty
                            st.success(f"已加入：{m.name} × {qty}")
    else:
        # 网格（桌面端）
        cols = st.columns(3)
        for i, m in enumerate(items):
            with cols[i % 3]:
                with st.container(border=True):
                    if m.image_url:
                        st.image(m.image_url, use_container_width=True)
                    st.subheader(m.name)
                    st.caption(m.category)
                    if m.description:
                        st.write(m.description)
                    st.write(format_currency(m.price))
                    qty_key = f"qty_{m.id}"
                    default_qty = st.session_state.cart.get(m.id, 0)
                    qty = st.number_input("数量", min_value=0, max_value=50, value=default_qty, step=1, key=qty_key)
                    if st.button("加入购物车", key=f"add_{m.id}"):
                        if qty <= 0:
                            st.warning("数量需要大于 0")
                        else:
                            st.session_state.cart[m.id] = qty
                            st.success(f"已加入：{m.name} × {qty}")

    st.divider()
    st.subheader("🛒 购物车")
    cart_rows = []
    for mid, qty in st.session_state.cart.items():
        item = db.query(MenuItem).get(mid)
        if not item:
            continue
        cart_rows.append({
            "菜品": item.name,
            "单价": format_currency(item.price),
            "数量": qty,
            "小计": format_currency(item.price * qty)
        })
    if cart_rows:
        df_cart = pd.DataFrame(cart_rows)
        st.dataframe(df_cart, use_container_width=True, hide_index=True)
        st.markdown(f"**合计：{format_currency(cart_total(db))}**")
        c1, c2 = st.columns(2)
        with c1:
            if st.button("清空购物车", type="secondary"):
                reset_cart()
                st.rerun()
    else:
        st.info("购物车为空，先选择菜品加入吧！")

    st.subheader("📋 联系信息")
    with st.form("place_order"):
        customer_name = st.text_input("姓名/昵称", placeholder="可选")
        table_no = st.text_input("桌号/房间号", value=table_param or "", placeholder="如 A3 或 外卖")
        contact = st.text_input("联系方式", placeholder="电话或微信（可选）")
        note = st.text_area("备注", placeholder="口味/过敏/打包等")
        submitted = st.form_submit_button("提交订单", type="primary", use_container_width=True)

        if submitted:
            if not st.session_state.cart:
                st.warning("购物车为空！")
            else:
                # 创建订单
                order = Order(
                    customer_name=customer_name.strip(),
                    table_no=table_no.strip(),
                    contact=contact.strip(),
                    note=note.strip(),
                    status="NEW",
                    total_price=0.0,
                    channel="onsite",
                    source_ip=st.context.headers.get("X-Forwarded-For", "") if hasattr(st, "context") else "",
                    created_at=datetime.now(TZ),
                    updated_at=datetime.now(TZ),
                )
                db.add(order)
                db.flush()  # 获取 order.id

                total = 0.0
                for mid, qty in st.session_state.cart.items():
                    item = db.query(MenuItem).get(mid)
                    if not item:
                        continue
                    total += item.price * qty
                    db.add(OrderItem(
                        order_id=order.id,
                        item_id=item.id,
                        item_name=item.name,
                        unit_price=item.price,
                        quantity=qty,
                    ))
                order.total_price = total
                order.updated_at = datetime.now(TZ)
                db.commit()
                reset_cart()
                st.success(f"下单成功！订单号 #{order.id}，金额 {format_currency(total)}")
                st.balloons()

    db.close()


# =============================
# 界面：查看订单（后台）
# =============================

def page_orders_admin():
    st.header("📦 订单管理（后台）")
    db = get_db()

    with st.expander("筛选", expanded=True):
        cols = st.columns(4)
        with cols[0]:
            statuses = ["NEW", "CONFIRMED", "PREPARING", "SERVED", "CANCELLED"]
            status_sel = st.multiselect("状态", statuses, default=statuses)
        with cols[1]:
            d_from = st.date_input("开始日期", value=datetime.now(TZ).date())
        with cols[2]:
            d_to = st.date_input("结束日期", value=datetime.now(TZ).date())
        with cols[3]:
            keyword = st.text_input("关键词", placeholder="姓名/桌号/联系方式")

    q = db.query(Order)
    q = q.filter(Order.created_at >= datetime(d_from.year, d_from.month, d_from.day, 0, 0, tzinfo=TZ))
    q = q.filter(Order.created_at <= datetime(d_to.year, d_to.month, d_to.day, 23, 59, 59, tzinfo=TZ))
    if status_sel:
        q = q.filter(Order.status.in_(status_sel))
    if keyword:
        like = f"%{keyword}%"
        q = q.filter((Order.customer_name.ilike(like)) | (Order.table_no.ilike(like)) | (Order.contact.ilike(like)))

    q = q.order_by(Order.created_at.desc())
    orders: List[Order] = q.all()

    # 汇总表
    rows = []
    for o in orders:
        rows.append({
            "订单号": o.id,
            "时间": o.created_at.astimezone(TZ).strftime("%Y-%m-%d %H:%M"),
            "姓名": o.customer_name,
            "桌号": o.table_no,
            "状态": o.status,
            "金额": o.total_price,
        })
    df = pd.DataFrame(rows)
    if not df.empty:
        df_display = df.copy()
        df_display["金额"] = df_display["金额"].map(format_currency)
        st.dataframe(df_display, use_container_width=True, hide_index=True)
    else:
        st.info("没有订单。")

    c1, c2 = st.columns(2)
    with c1:
        if st.button("导出为 CSV"):
            csv = df.to_csv(index=False).encode("utf-8-sig")
            st.download_button("下载订单.csv", csv, file_name="orders_export.csv", mime="text/csv")

    st.divider()
    st.subheader("订单详情 / 快速更新")

    if orders:
        oid = st.selectbox("选择订单", options=[o.id for o in orders], format_func=lambda x: f"#{x}")
        order = next((o for o in orders if o.id == oid), None)
        if order:
            st.markdown(f"**订单号：** #{order.id}")
            st.markdown(f"**创建时间：** {order.created_at.astimezone(TZ).strftime('%Y-%m-%d %H:%M:%S')}  ")
            st.markdown(f"**客户：** {order.customer_name}  |  **桌号：** {order.table_no}  |  **联系方式：** {order.contact}")
            if order.note:
                st.markdown(f"**备注：** {order.note}")
            st.markdown("**菜品**：")
            items_df = pd.DataFrame([
                {
                    "菜品": it.item_name,
                    "单价": format_currency(it.unit_price),
                    "数量": it.quantity,
                    "小计": format_currency(it.unit_price * it.quantity),
                }
                for it in order.items
            ])
            st.dataframe(items_df, use_container_width=True, hide_index=True)
            st.markdown(f"**合计：{format_currency(order.total_price)}**")

            new_status = st.selectbox(
                "更新状态",
                options=["NEW", "CONFIRMED", "PREPARING", "SERVED", "CANCELLED"],
                index=["NEW", "CONFIRMED", "PREPARING", "SERVED", "CANCELLED"].index(order.status),
            )
            if st.button("保存状态"):
                order.status = new_status
                order.updated_at = datetime.now(TZ)
                db.commit()
                st.success("已更新订单状态")
                st.rerun()

            if st.button("删除该订单", type="secondary"):
                db.delete(order)
                db.commit()
                st.warning("订单已删除")
                st.rerun()

    db.close()


# =============================
# 界面：菜单管理（后台）
# =============================

def page_menu_admin():
    st.header("📚 菜单管理（后台）")
    db = get_db()

    st.subheader("当前菜单")
    data = []
    for m in db.query(MenuItem).order_by(MenuItem.category, MenuItem.name).all():
        data.append({
            "ID": m.id,
            "名称": m.name,
            "分类": m.category,
            "价格": m.price,
            "是否上架": m.is_available,
            "描述": m.description,
            "图片URL": m.image_url,
        })
    df = pd.DataFrame(data)
    st.dataframe(df, use_container_width=True)

    st.divider()
    st.subheader("新增菜品")
    with st.form("add_item"):
        name = st.text_input("名称")
        category = st.text_input("分类", value="主食")
        price = st.number_input("价格", min_value=0.0, step=0.5)
        description = st.text_area("描述", placeholder="可选")
        image_url = st.text_input("图片URL", placeholder="可选")
        avail = st.checkbox("上架", value=True)
        ok = st.form_submit_button("添加", type="primary")
        if ok:
            if not name:
                st.warning("名称必填")
            else:
                db.add(MenuItem(name=name, category=category or "主食", price=float(price),
                                description=description, image_url=image_url, is_available=avail))
                db.commit()
                st.success("已添加")
                st.rerun()

    st.divider()
    st.subheader("编辑 / 下架 / 删除")
    all_items = db.query(MenuItem).order_by(MenuItem.category, MenuItem.name).all()
    if all_items:
        selected = st.selectbox("选择菜品", options=all_items, format_func=lambda m: f"[{m.category}] {m.name} (¥{m.price})")
        if selected:
            with st.form("edit_item"):
                e_name = st.text_input("名称", value=selected.name)
                e_category = st.text_input("分类", value=selected.category)
                e_price = st.number_input("价格", min_value=0.0, step=0.5, value=float(selected.price))
                e_desc = st.text_area("描述", value=selected.description)
                e_img = st.text_input("图片URL", value=selected.image_url)
                e_avail = st.checkbox("上架", value=bool(selected.is_available))
                c1, c2, c3 = st.columns(3)
                with c1:
                    save_ok = st.form_submit_button("保存修改", type="primary")
                with c2:
                    del_ok = st.form_submit_button("删除该菜品", type="secondary")
                with c3:
                    pass

            if save_ok:
                selected.name = e_name
                selected.category = e_category
                selected.price = float(e_price)
                selected.description = e_desc
                selected.image_url = e_img
                selected.is_available = e_avail
                db.commit()
                st.success("已更新")
                st.rerun()

            if del_ok:
                db.delete(selected)
                db.commit()
                st.warning("已删除")
                st.rerun()
    else:
        st.info("暂无菜品，请先新增。")

    st.divider()
    st.subheader("批量导入菜品（CSV）")
    st.caption("CSV 需要包含列：name,price,category,description,image_url,is_available（可选）")
    up = st.file_uploader("上传 CSV", type=["csv"])
    if up is not None:
        try:
            dfu = pd.read_csv(up)
            required = {"name", "price", "category"}
            if not required.issubset(set(map(str.lower, dfu.columns))):
                st.error("CSV 至少包含 name, price, category 列")
            else:
                # 统一列名到小写
                dfu.columns = [c.lower() for c in dfu.columns]
                n = 0
                for _, r in dfu.iterrows():
                    db.add(MenuItem(
                        name=str(r.get("name", "")).strip(),
                        price=float(r.get("price", 0.0)),
                        category=str(r.get("category", "主食")),
                        description=str(r.get("description", "")),
                        image_url=str(r.get("image_url", "")),
                        is_available=bool(r.get("is_available", True)),
                    ))
                    n += 1
                db.commit()
                st.success(f"已导入 {n} 条")
                st.rerun()
        except Exception as e:
            st.error(f"导入失败：{e}")

    db.close()


# =============================
# 鉴权包装器
# =============================

def require_admin() -> bool:
    st.sidebar.markdown("### 🔐 后台登录")
    pw = st.sidebar.text_input("管理员密码", type="password")
    ok = st.sidebar.button("进入后台")
    if ok:
        st.session_state.get("_admin_ok")
        st.session_state["_admin_ok"] = (pw == ADMIN_PASSWORD)
    return st.session_state.get("_admin_ok", False)


# =============================
# 二维码页面（后台）
# =============================

def page_qr():
    st.header("📱 桌贴二维码生成（后台）")
    if qrcode is None:
        st.error("未安装 qrcode 库。请先运行：pip install qrcode[pil] pillow")
        return

    st.caption("将点单链接做成二维码，贴在桌面/收银台。手机扫码直接进入点单页。")

    # 1) 基础设置
    default_url = FRONTEND_URL or "http://localhost:8501"
    base_url = st.text_input("点单页面链接（部署后的公网地址）", value=default_url, help="例如 https://your-domain.com 或 http://IP:8501")
    param_key = st.text_input("桌号参数名", value="table", help="二维码将以 ?table=XXX 的形式附加到链接")
    mobile_mode = st.checkbox("二维码启用移动端列表布局（mode=list）", value=True)

    st.divider()

    # 2) 单个桌号二维码
    st.subheader("单个桌号")
    single_table = st.text_input("桌号（如 A3）", value="A1")
    if st.button("生成单个二维码"):
        url = base_url.rstrip("/") + f"/?{param_key}={single_table}" + ("&mode=list" if mobile_mode else "")
        img = qrcode.make(url)
        bio = BytesIO()
        img.save(bio, format="PNG")
        st.image(bio.getvalue(), caption=url, use_container_width=False)
        st.download_button(
            "下载该二维码PNG",
            data=bio.getvalue(),
            file_name=f"qr_{single_table}.png",
            mime="image/png",
        )

    st.divider()

    # 3) 批量桌号二维码
    st.subheader("批量生成")
    c1, c2, c3 = st.columns(3)
    with c1:
        prefix = st.text_input("桌号前缀", value="A")
    with c2:
        start_no = st.number_input("起始数字", min_value=1, value=1, step=1)
    with c3:
        count = st.number_input("数量", min_value=1, value=10, step=1)

    if st.button("批量生成ZIP"):
        zbio = BytesIO()
        with zipfile.ZipFile(zbio, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
            for i in range(int(start_no), int(start_no) + int(count)):
                tid = f"{prefix}{i}"
                url = base_url.rstrip("/") + f"/?{param_key}={tid}" + ("&mode=list" if mobile_mode else "")
                img = qrcode.make(url)
                bio = BytesIO()
                img.save(bio, format="PNG")
                zf.writestr(f"qr_{tid}.png", bio.getvalue())
        st.success(f"已生成 {int(count)} 个二维码")
        st.download_button("下载二维码打包ZIP", data=zbio.getvalue(), file_name="qrs.zip", mime="application/zip")


# =============================
# 主程序入口
# =============================

def main():
    st.set_page_config(page_title="点单系统", layout="wide")
    st.title("🍽️ 点单系统")
    st.caption("自助可改菜单 · 后台看订单 · 可接入 SQLite / PostgreSQL")

    init_db()

    # 侧边栏导航
    page = st.sidebar.radio("页面", ["客户点单", "查看订单（后台）", "菜单管理（后台）", "桌贴二维码（后台）"])  

    if page == "客户点单":
        page_order()
    else:
        if not require_admin():
            st.warning("请输入正确的管理员密码以进入后台。默认密码为 ‘changeme’，请通过环境变量 ADMIN_PASSWORD 修改！")
            return
        if page == "查看订单（后台）":
            page_orders_admin()
        elif page == "菜单管理（后台）":
            page_menu_admin()
        elif page == "桌贴二维码（后台）":
            page_qr()


if __name__ == "__main__":
    main()
