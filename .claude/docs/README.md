# Documentation Index

## Core Guides
- [architecture.md](architecture.md): High-level design, gated pipeline pattern, and layer ownership. *Read this first to understand how data moves.*
- [data-model.md](data-model.md): Schema definitions, watermark logic, and the lifecycle of a record. *Read this when designing new tables or fixing data gaps.*
- [module-map.md](module-map.md): Directory structure and file responsibilities. *Read this to find where a specific piece of logic lives.*
- [interfaces.md](interfaces.md): API and CLI entry points for orchestration, publishing, and the dashboard. *Read this when debugging pipeline triggers.*

## Standards & Operations
- [conventions.md](conventions.md): Naming rules, engineering patterns, and "Anti-Patterns to Avoid". *Read this before creating a PR.*
- [workflow.md](workflow.md): Local development commands (`make`), CI pipeline, and testing tiers. *Read this to set up your environment or run tests.*
- [integrations.md](integrations.md): Third-party SDKs (Spark, Databricks, PG) and environment variable requirements. *Read this when configuring secrets or connections.*

## Reference & Troubleshooting
- [glossary.md](glossary.md): Definitions of domain terms (SCD1, Medallion, etc.) and project jargon. *Read this if you encounter unfamiliar terminology.*
- [gotchas.md](gotchas.md): Known fragile areas, technical debt, and "Do Not Edit" zones. *Read this before making changes to watermarks or migrations.*
