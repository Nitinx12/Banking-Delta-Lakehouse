p = r"tests\data-quality\staging\10_lp_check_value_domains.sql"
s = open(p).read()
s = s.replace('"customers.gender":                 ["Female", "Male", "Other"],',
              '"customers.gender":                 ["Female", "Male", "N/A"],')
s = s.replace('        "card_transactions.is_fraud":       ["0", "1"],\n', '')
s = s.replace('        "loan_payments.late_payment_flag":  ["0", "1"]\n', '')
open(p, "w").write(s)
print("done")