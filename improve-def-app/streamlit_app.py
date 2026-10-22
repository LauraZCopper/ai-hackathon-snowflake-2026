import datetime
import difflib
import json
import re
import textwrap

import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()
SCHEMA = "HACKATHON_DB.DEFINITIONS"
MODEL_SCHEMA = "HACKATHON_DB.MODEL"
SEMANTIC_VIEW = "HACKATHON_DB.DEFINITIONS.DEFINITIONS_SV"

st.set_page_config(page_title="Column Definitions", layout="wide")
st.title("Column Definitions Catalogue")
st.caption(
    "Browse definitions and suggest changes. Suggestions are reviewed by the data team "
    "before anything goes live."
)

# Demo role switch. In production this is a Snowflake role / app permission, not a toggle.
role = st.sidebar.radio("View as", ["Product user", "Data team"])
reviewer = ""
if role == "Data team":
    reviewer = st.sidebar.text_input("Your email (reviewer)")


# ------------------------------------------------------------------ data access
@st.cache_data(ttl=30)
def load_definitions():
    return session.sql(f"""
        SELECT d.TABLE_NAME, d.COLUMN_NAME, d.DATA_TYPE, d.CURRENT_DEFINITION,
               d.DOMAIN, d.OWNER,
               (SELECT COUNT(*) FROM {SCHEMA}.DEFINITION_REQUESTS r
                 WHERE r.TABLE_NAME = d.TABLE_NAME
                   AND r.COLUMN_NAME = d.COLUMN_NAME
                   AND r.STATUS = 'PENDING') AS PENDING_REQUESTS
        FROM {SCHEMA}.COLUMN_DEFINITIONS d
        ORDER BY d.TABLE_NAME, d.ORDINAL_POSITION
    """).to_pandas()


def load_requests():
    return session.sql(f"""
        SELECT REQUEST_ID, TABLE_NAME, COLUMN_NAME, CURRENT_DEFINITION,
               PROPOSED_DEFINITION, REASON, REQUESTED_BY, REQUESTED_AT,
               STATUS, REVIEWED_BY, REVIEWED_AT, REVIEW_COMMENT
        FROM {SCHEMA}.DEFINITION_REQUESTS
        ORDER BY REQUESTED_AT DESC
    """).to_pandas()


# ------------------------------------------------------------- yml patch builder
def column_yml(model, column, description):
    """The model-yml snippet for one column, formatted like the dbt schema files."""
    wrapped = textwrap.wrap(description or "", width=88) or [""]
    lines = [
        "models:",
        f"  - name: {model}",
        "    columns:",
        f"      - name: {column}",
        "        description: >-",
    ]
    lines += [f"          {w}" for w in wrapped]
    return lines


def yml_patch(domain, table, column, old, new):
    slug = re.sub(r"\W+", "_", (domain or "unassigned").lower()).strip("_")
    path = f"dwh_etl/models/modelled/{slug}/_{slug}_models.yml"
    diff = difflib.unified_diff(
        column_yml(table.lower(), column.lower(), old),
        column_yml(table.lower(), column.lower(), new),
        fromfile=f"a/{path}",
        tofile=f"b/{path}",
        lineterm="",
        n=10,
    )
    return "\n".join(diff)


# ---------------------------------------------------------------------- actions
def set_status(request_id, status, comment):
    session.sql(
        f"""UPDATE {SCHEMA}.DEFINITION_REQUESTS
            SET STATUS = ?, REVIEWED_BY = ?, REVIEWED_AT = CURRENT_TIMESTAMP(),
                REVIEW_COMMENT = ?
            WHERE REQUEST_ID = ? AND STATUS = 'PENDING'""",
        params=[status, reviewer, comment, int(request_id)],
    ).collect()


def simulate_deploy(req, defs):
    """Stands in for: PR merged -> dbt run -> persist_docs writes the column comment."""
    table, column = req["TABLE_NAME"], req["COLUMN_NAME"]
    known = defs[(defs["TABLE_NAME"] == table) & (defs["COLUMN_NAME"] == column)]
    if known.empty or not re.fullmatch(r"[A-Z0-9_]+", table + column):
        st.error("Column not found in the model schema.")
        return
    text = req["PROPOSED_DEFINITION"].replace("\\", "\\\\").replace("'", "''")
    session.sql(
        f"ALTER TABLE {MODEL_SCHEMA}.{table} ALTER COLUMN {column} COMMENT '{text}'"
    ).collect()
    session.sql(
        f"UPDATE {SCHEMA}.DEFINITION_REQUESTS SET STATUS = 'DEPLOYED' WHERE REQUEST_ID = ?",
        params=[int(req["REQUEST_ID"])],
    ).collect()
    load_definitions.clear()
    # Stands in for the col_desc macro: the semantic view is regenerated from the
    # (now updated) column comments, so the AI sees the new definition.
    try:
        rebuild_semantic_view()
    except Exception as e:  # noqa: BLE001
        st.warning(f"Definition deployed, but the semantic view could not be rebuilt: {e}")


# ---------------------------------------------------- semantic view generation
# Structure is fixed here; every table, dimension and fact comment is read from the
# column comments in Snowflake, so the model comments stay the single source.
SV_TABLES = {
    "CLIENTS": {"alias": "clients", "pk": ["CLIENT_ID"], "syn": ["customers", "organisations"]},
    "ORDERS": {"alias": "orders", "pk": ["ORDER_ID"], "syn": ["trades", "transactions"]},
    "CLIENT_BALANCES": {"alias": "balances", "pk": None, "syn": ["holdings", "assets under custody", "AuC"]},
}
SV_RELATIONSHIPS = [
    ("orders_to_clients", "orders", "CLIENT_ID", "clients"),
    ("balances_to_clients", "balances", "CLIENT_ID", "clients"),
]
# (table alias, metric name, expression, comment or ("col", TABLE, COLUMN), synonyms)
SV_METRICS = [
    ("clients", "client_count", "COUNT(clients.client_id)", "Number of clients.", ["number of clients"]),
    ("orders", "order_count", "COUNT(orders.order_id)", "Number of orders.", ["number of orders"]),
    ("orders", "traded_value_usd", "SUM(orders.quantity * orders.price_usd)",
     "Traded value in USD: quantity multiplied by execution price. Respect the ORDER_STATUS definition.",
     ["trading volume", "volume", "traded volume"]),
    ("orders", "total_fees_usd", "SUM(orders.fee_usd)", "Total fees charged in USD.", ["fees", "revenue"]),
    ("balances", "total_balance_usd", "SUM(balances.balance_usd)", ("col", "CLIENT_BALANCES", "BALANCE_USD"),
     ["AuC", "assets under custody", "total holdings"]),
]


def q(text):
    """Quote a string literal for Snowflake DDL."""
    return "'" + (text or "").replace("\\", "\\\\").replace("'", "''") + "'"


def build_semantic_view_ddl(defs_df):
    tbl = session.sql(
        "SELECT TABLE_NAME, COMMENT FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES "
        "WHERE TABLE_SCHEMA = 'MODEL'"
    ).to_pandas()
    tbl_comment = dict(zip(tbl["TABLE_NAME"], tbl["COMMENT"].fillna("")))
    def_of = {(r.TABLE_NAME, r.COLUMN_NAME): r.CURRENT_DEFINITION for r in defs_df.itertuples()}

    tables, facts, dims, metrics = [], [], [], []
    for t, cfg in SV_TABLES.items():
        pk = f"\n      PRIMARY KEY ({', '.join(cfg['pk'])})" if cfg["pk"] else ""
        syn = ", ".join(q(x) for x in cfg["syn"])
        tables.append(
            f"    {cfg['alias']} AS {MODEL_SCHEMA}.{t}{pk}\n"
            f"      WITH SYNONYMS = ({syn})\n      COMMENT = {q(tbl_comment.get(t, ''))}"
        )
        for r in defs_df[defs_df["TABLE_NAME"] == t].itertuples():
            comment = f"\n      COMMENT = {q(r.CURRENT_DEFINITION)}" if r.CURRENT_DEFINITION else ""
            entry = f"    {cfg['alias']}.{r.COLUMN_NAME.lower()} AS {r.COLUMN_NAME}{comment}"
            (facts if r.DATA_TYPE in ("NUMBER", "FIXED", "FLOAT") else dims).append(entry)

    for alias, name, expr, comment, syn in SV_METRICS:
        if isinstance(comment, tuple):
            comment = def_of.get((comment[1], comment[2]), "")
        synonyms = ", ".join(q(x) for x in syn)
        metrics.append(
            f"    {alias}.{name} AS {expr}\n      WITH SYNONYMS = ({synonyms})\n      COMMENT = {q(comment)}"
        )

    sep = ",\n"
    rels = sep.join(
        f"    {n} AS {frm} ({col}) REFERENCES {to}" for n, frm, col, to in SV_RELATIONSHIPS
    )
    return (
        f"CREATE OR REPLACE SEMANTIC VIEW {SEMANTIC_VIEW}\n"
        f"  TABLES (\n{sep.join(tables)}\n  )\n"
        f"  RELATIONSHIPS (\n{rels}\n  )\n"
        f"  FACTS (\n{sep.join(facts)}\n  )\n"
        f"  DIMENSIONS (\n{sep.join(dims)}\n  )\n"
        f"  METRICS (\n{sep.join(metrics)}\n  )\n"
        f"  COMMENT = 'Generated from the column comments in {MODEL_SCHEMA}.'"
    )


def rebuild_semantic_view():
    ddl = build_semantic_view_ddl(load_definitions())
    session.sql(ddl).collect()
    return ddl


def ask_analyst(question):
    """Call Cortex Analyst on the semantic view and return its text, SQL and result."""
    body = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        "semantic_view": SEMANTIC_VIEW,
    }
    try:
        # Warehouse runtime
        import _snowflake

        resp = _snowflake.send_snow_api_request(
            "POST", "/api/v2/cortex/analyst/message", {}, {}, body, None, 60000
        )
        status, payload = resp["status"], json.loads(resp["content"])
    except ImportError:
        # Container runtime has no _snowflake: call the REST API over HTTPS with the
        # session token. Best effort; untested.
        import os

        import requests

        conn = session._conn._conn
        host = os.environ.get("SNOWFLAKE_HOST") or conn.host
        r = requests.post(
            f"https://{host}/api/v2/cortex/analyst/message",
            json=body,
            headers={
                "Authorization": f'Snowflake Token="{conn.rest.token}"',
                "Content-Type": "application/json",
            },
            timeout=60,
        )
        status, payload = r.status_code, r.json()
    if status >= 400:
        raise RuntimeError(payload.get("message", str(payload)))
    text, sql = [], None
    for item in payload["message"]["content"]:
        if item["type"] == "text":
            text.append(item["text"])
        elif item["type"] == "sql":
            sql = item["statement"]
    df = session.sql(sql).to_pandas() if sql else None
    return {"text": " ".join(text), "sql": sql, "df": df}


def run_question(question, defs_df):
    result = ask_analyst(question)
    result["question"] = question
    result["time"] = datetime.datetime.now().strftime("%H:%M:%S")
    wanted = [("CLIENT_BALANCES", "BALANCE_USD"), ("ORDERS", "ORDER_STATUS"), ("CLIENTS", "IS_ACTIVE")]
    result["defs"] = {
        c: defs_df[(defs_df["TABLE_NAME"] == t) & (defs_df["COLUMN_NAME"] == c)].iloc[0]["CURRENT_DEFINITION"]
        for t, c in wanted
    }
    return result


defs = load_definitions()

tab_catalogue, tab_suggest, tab_review, tab_requests, tab_ask = st.tabs(
    ["Catalogue", "Suggest a change", "Review (data team)", "Requests", "Ask the data"]
)

# ---------------------------------------------------------------- Catalogue
with tab_catalogue:
    c1, c2, c3 = st.columns([3, 2, 2])
    search = c1.text_input("Search column or definition", placeholder="e.g. balance, active, fee")
    domains = c2.multiselect("Domain", sorted(defs["DOMAIN"].unique()))
    tables = c3.multiselect("Table", sorted(defs["TABLE_NAME"].unique()))

    view = defs.copy()
    if search:
        s = search.lower()
        view = view[
            view["COLUMN_NAME"].str.lower().str.contains(s, na=False)
            | view["CURRENT_DEFINITION"].str.lower().str.contains(s, na=False)
        ]
    if domains:
        view = view[view["DOMAIN"].isin(domains)]
    if tables:
        view = view[view["TABLE_NAME"].isin(tables)]

    st.write(f"{len(view)} of {len(defs)} columns")
    st.dataframe(
        view,
        use_container_width=True,
        hide_index=True,
        column_config={
            "CURRENT_DEFINITION": st.column_config.TextColumn("Definition", width="large"),
            "PENDING_REQUESTS": st.column_config.NumberColumn("Pending requests"),
        },
    )

# ----------------------------------------------------------- Suggest change
with tab_suggest:
    st.subheader("Suggest a new definition")

    table = st.selectbox("Table", sorted(defs["TABLE_NAME"].unique()))
    cols = defs[defs["TABLE_NAME"] == table]["COLUMN_NAME"].tolist()
    column = st.selectbox("Column", cols)

    row = defs[(defs["TABLE_NAME"] == table) & (defs["COLUMN_NAME"] == column)].iloc[0]
    st.info(f"**Current definition:** {row['CURRENT_DEFINITION'] or '(none)'}")
    if row["PENDING_REQUESTS"] > 0:
        st.warning(
            f"{int(row['PENDING_REQUESTS'])} pending request(s) already exist for this column. "
            "You can still submit, but check the Requests tab first."
        )

    with st.form("suggest_form", clear_on_submit=True):
        proposed = st.text_area("Proposed definition", height=100)
        reason = st.text_area("Why does this need to change?", height=80)
        requester = st.text_input("Your email")
        submitted = st.form_submit_button("Submit request")

    if submitted:
        proposed, reason, requester = proposed.strip(), reason.strip(), requester.strip()
        if len(proposed) < 10:
            st.error("Please enter a proposed definition (at least 10 characters).")
        elif proposed == row["CURRENT_DEFINITION"]:
            st.error("The proposed definition is identical to the current one.")
        elif not requester:
            st.error("Please enter your email so the data team can follow up.")
        else:
            session.sql(
                f"""INSERT INTO {SCHEMA}.DEFINITION_REQUESTS
                    (TABLE_NAME, COLUMN_NAME, CURRENT_DEFINITION,
                     PROPOSED_DEFINITION, REASON, REQUESTED_BY)
                    VALUES (?, ?, ?, ?, ?, ?)""",
                params=[table, column, row["CURRENT_DEFINITION"], proposed, reason, requester],
            ).collect()
            load_definitions.clear()
            st.success("Request submitted. The data team will review it.")

# ------------------------------------------------------------------- Review
with tab_review:
    if role != "Data team":
        st.info("Switch to **Data team** in the sidebar to review requests.")
    else:
        reqs = load_requests()

        # ---- 1. Pending requests -------------------------------------------
        st.subheader("Pending requests")
        pending = reqs[reqs["STATUS"] == "PENDING"]

        if pending.empty:
            st.success("No pending requests.")
        else:
            labels = {
                int(r.REQUEST_ID): f"#{int(r.REQUEST_ID)}  {r.TABLE_NAME}.{r.COLUMN_NAME}  ({r.REQUESTED_BY})"
                for r in pending.itertuples()
            }
            chosen = st.selectbox(
                "Request", list(labels.keys()), format_func=lambda i: labels[i]
            )
            req = pending[pending["REQUEST_ID"] == chosen].iloc[0]

            live = defs[
                (defs["TABLE_NAME"] == req["TABLE_NAME"])
                & (defs["COLUMN_NAME"] == req["COLUMN_NAME"])
            ]
            live_def = live.iloc[0]["CURRENT_DEFINITION"] if not live.empty else ""
            domain = live.iloc[0]["DOMAIN"] if not live.empty else None

            left, right = st.columns(2)
            left.markdown("**Currently deployed**")
            left.info(live_def or "(none)")
            right.markdown("**Proposed**")
            right.success(req["PROPOSED_DEFINITION"])
            st.markdown(f"**Reason:** {req['REASON'] or '-'}")

            if live_def != (req["CURRENT_DEFINITION"] or ""):
                st.warning(
                    "The deployed definition has changed since this request was raised. "
                    "Check the diff before approving."
                )
            others = pending[
                (pending["TABLE_NAME"] == req["TABLE_NAME"])
                & (pending["COLUMN_NAME"] == req["COLUMN_NAME"])
                & (pending["REQUEST_ID"] != req["REQUEST_ID"])
            ]
            if not others.empty:
                st.warning(
                    f"{len(others)} other pending request(s) for this column. "
                    "Approving one will leave the others stale."
                )

            st.markdown("**Change that approval would put in the dbt model yml**")
            st.code(
                yml_patch(
                    domain,
                    req["TABLE_NAME"],
                    req["COLUMN_NAME"],
                    live_def,
                    req["PROPOSED_DEFINITION"],
                ),
                language="diff",
            )
            st.caption(
                "The yml stays the source of truth. The semantic view picks the new text up "
                "from it on the next deploy, so there is no second edit."
            )

            comment = st.text_input("Review comment (required to reject)", key=f"c_{chosen}")
            b1, b2, _ = st.columns([1, 1, 4])
            if b1.button("Approve", type="primary", key=f"a_{chosen}"):
                if not reviewer:
                    st.error("Enter your email in the sidebar first.")
                else:
                    set_status(chosen, "APPROVED", comment)
                    st.rerun()
            if b2.button("Reject", key=f"r_{chosen}"):
                if not reviewer:
                    st.error("Enter your email in the sidebar first.")
                elif not comment.strip():
                    st.error("Please add a comment explaining the rejection.")
                else:
                    set_status(chosen, "REJECTED", comment.strip())
                    st.rerun()

        # ---- 2. Approved, waiting for deploy -------------------------------
        st.divider()
        st.subheader("Approved, awaiting deploy")
        st.caption(
            "In production: the PR is merged and the next dbt run applies persist_docs. "
            "Here the button writes the column comment directly to simulate that."
        )
        approved = reqs[reqs["STATUS"] == "APPROVED"]
        if approved.empty:
            st.write("Nothing waiting.")
        for _, r in approved.iterrows():
            c_a, c_b = st.columns([5, 1])
            c_a.write(f"**#{int(r['REQUEST_ID'])} {r['TABLE_NAME']}.{r['COLUMN_NAME']}**: {r['PROPOSED_DEFINITION']}")
            if c_b.button("Simulate merge + dbt run", key=f"d_{int(r['REQUEST_ID'])}"):
                simulate_deploy(r, defs)
                st.rerun()

# ------------------------------------------------------------------ Requests
with tab_requests:
    st.subheader("All requests")
    reqs_all = load_requests()
    status_filter = st.multiselect(
        "Status",
        ["PENDING", "APPROVED", "REJECTED", "DEPLOYED"],
        default=["PENDING", "APPROVED"],
    )
    if status_filter:
        reqs_all = reqs_all[reqs_all["STATUS"].isin(status_filter)]
    st.dataframe(reqs_all, use_container_width=True, hide_index=True)

# ------------------------------------------------------------------ Ask the data
with tab_ask:
    st.subheader("Ask the data (Cortex Analyst)")
    st.caption(
        "Answers come from a semantic view generated from the column definitions. "
        "Ask a question, approve a definition change in the Review tab, then ask again."
    )
    if "runs" not in st.session_state:
        st.session_state["runs"] = []

    top1, top2 = st.columns([1, 1])
    if top1.button("Build / rebuild semantic view"):
        try:
            rebuild_semantic_view()
            st.success("Semantic view rebuilt from the current column definitions.")
        except Exception as e:  # noqa: BLE001
            st.error(f"Could not build the semantic view: {e}")
    if top2.button("Clear history"):
        st.session_state["runs"] = []

    presets = [
        "What is our total assets under custody in USD?",
        "What is our total traded volume in USD?",
        "How many active clients do we have?",
    ]
    asked = None
    for p in presets:
        if st.button(p, key=f"preset_{p}"):
            asked = p
    custom = st.text_input("Or ask your own question")
    if st.button("Ask") and custom.strip():
        asked = custom.strip()

    if asked:
        with st.spinner("Asking Cortex Analyst..."):
            try:
                st.session_state["runs"].insert(0, run_question(asked, load_definitions()))
            except Exception as e:  # noqa: BLE001
                st.error(f"Question failed: {e}")

    for n, run in enumerate(st.session_state["runs"]):
        with st.expander(f"{run['time']}  {run['question']}", expanded=(n == 0)):
            if run["text"]:
                st.write(run["text"])
            if run["sql"]:
                st.code(run["sql"], language="sql")
            if run["df"] is not None:
                st.dataframe(run["df"], use_container_width=True, hide_index=True)
            st.caption(
                "Definitions in force: "
                + " | ".join(f"{k}: {v}" for k, v in run["defs"].items())
            )