# Report builder

See `docs/REPORTING.md` for the full design, build plan and rules.

Quick commands:

```bash
make report-fixture    # render all fixtures, no TeX (part of `make ci`)
make report-pdf        # compile all fixtures to PDF (needs TeX)
make report-tex        # compile + check log and page budget
make report-docker     # compile inside the TeX image (needs Docker)
make report            # daily report for the warehouse in .env
make report-incident RUN=<run id>   # incident report for one run
make report-weekly     # weekly digest
```