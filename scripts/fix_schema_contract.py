import re
p = r"tests\data-quality\staging\07_lp_check_schema_contract.sql"
s = open(p).read()
new_contract = """v_contract CONSTANT JSONB := '{
        "accounts": {"account_id":"int","customer_id":"int","branch_id":"int","account_type":"text","balance":"num","open_date":"date","status":"text"},
        "branches": {"branch_id":"int","branch_name":"text","city":"text","state":"text","opened_date":"date","ifsc_code":"text"},
        "cards": {"card_id":"int","customer_id":"int","account_id":"int","card_type":"text","issue_date":"date","expiry_date":"date","credit_limit":"num","status":"text"},
        "customers": {"customer_id":"int","customer_name":"text","gender":"text","date_of_birth":"date","city":"text","state":"text","phone":"text","email":"text","occupation":"text","annual_income":"num","join_date":"date","credit_score":"num"},
        "employees": {"employee_id":"int","employee_name":"text","branch_id":"int","role":"text","hire_date":"date","salary":"num"},
        "loans": {"loan_id":"int","customer_id":"int","branch_id":"int","loan_type":"text","loan_amount":"num","interest_rate":"num","term_months":"int","start_date":"date","status":"text"},
        "loan_payments": {"payment_id":"int","loan_id":"int","payment_date":"date","amount_paid":"num","principal_component":"num","interest_component":"num","is_late":"bool","amount_check":"text"},
        "transactions": {"transaction_id":"int","account_id":"int","txn_date":"date","txn_type":"text","amount":"num","channel":"text","merchant_category":"text"},
        "card_transactions": {"card_txn_id":"int","card_id":"int","merchant_category":"text","is_fraud":"bool","amount":"num","txn_date":"date"},
        "support_tickets": {"ticket_id":"int","customer_id":"int","issue_type":"text","date_opened":"date","date_resolved":"date","status":"text","satisfaction_score":"int"}
    }'::JSONB;"""
s = re.sub(r"v_contract CONSTANT JSONB := '.*?'::JSONB;", new_contract, s, count=1, flags=re.S)
s = s.replace("v_meta_cols CONSTANT TEXT[] := ARRAY['_batch_id', '_loaded_at'];", "v_meta_cols CONSTANT TEXT[] := ARRAY['source_batch_id', 'source_loaded_at', 'row_added_at', 'row_updated_at'];")
open(p, "w").write(s)
print("done")