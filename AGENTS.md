<!--
CANONICAL FILE — This is THE agent context file for unitycatalog.
CLAUDE.md in this repo is a SYMLINK pointing here.
→ Edit THIS file (AGENTS.md), not CLAUDE.md.
→ If CLAUDE.md stops being a symlink, run `ln -sf AGENTS.md CLAUDE.md` to restore.

See /Users/apurupreddy/maptic_git/AGENTS.md for workspace-level context
(cross-repo system map, branch discipline, deploy flow, naming rules,
port conventions, and the AGENTS.md ↔ CLAUDE.md convention).
-->

# CLAUDE.md - Unity Catalog

## Project Overview

**Unity Catalog OSS** — universal catalog for data and AI assets (Apache 2.0), providing multi-format support, multi-engine access, and unified governance. Maptic runs this as a fork on branch `fix/flux-engine-checkout` (base: upstream v0.5.0).

## Architecture

```
AI Agent ──► Unity Catalog Server (port 8080)
                    │
                    ├──► PostgreSQL (metadata store)
                    │
                    ├──► Object Storage (S3/MinIO/ADLS/GCS)
                    │         │
                    │         ▼
                    └──► Spark Driver ◄──► Delta Lake / Iceberg / Parquet / ...
                                    │
                                    └──► Lineage back to UC
```

**Key principle**: Unified governance for tables, files, functions, and AI models with RBAC via JCasbin.

## Project Structure

```
unitycatalog/
├── README.md                    # Main documentation
├── roadmap.md                   # Project roadmap
├── build.sbt                    # Scala build config (799 lines)
├── server/src/main/java/io/unitycatalog/server/
│   ├── UnityCatalogServer.java  # Main entry (port 8080), Armeria server builder
│   ├── URLTranscoderVerticle.java # Backward compatibility port transcoder
│   ├── service/                 # Business logic: CatalogService, SchemaService, TableService, etc.
│   ├── persist/                 # Hibernate/JPA repositories and DAOs
│   │   ├── dao/                 # JPA entities (DeltaCommitDAO, TableDAO, etc.)
│   │   └── DeltaCommitRepository.java  # Delta commit tracking (PostgreSQL DELETE LIMIT fix applied)
│   ├── auth/                    # JCasbinAuthorizer, AllowingAuthorizer, security decorators
│   ├── delta/serde/             # Delta serialization/deserialization
│   └── security/               # JwtToken, SecurityConfiguration, SecurityContext
├── api/
│   ├── all.yaml                 # OpenAPI 3.0 spec (~114KB) — generated models/controllers
│   ├── control.yaml             # Control plane API
│   └── Models/                  # Generated model documentation
├── ai/
│   ├── core/src/unitycatalog/ai/core/
│   │   ├── client.py           # UnitycatalogFunctionClient — manages and executes UC functions
│   │   ├── base.py             # BaseFunctionClient abstract class
│   │   └── executor/           # local, local_subprocess execution modes
│   └── integrations/            # Anthropic, LangChain, LangGraph, OpenAI, LlamaIndex, LiteLLM, etc.
├── clients/
│   ├── python/                  # Generated Python SDK
│   └── java/                    # Generated Java SDK
├── connectors/spark/
│   └── src/main/scala/io/unitycatalog/spark/
│       └── UCSingleCatalog.scala # Spark catalog implementation for connecting to UC
├── ui/                          # React UI
├── helm/                        # Kubernetes Helm chart
├── bin/
│   ├── start-uc-server         # Start UC server script
│   └── uc                       # CLI tool
├── etc/conf/
│   └── server.properties        # Server config (storage-root, authorization, S3)
└── docs/
```

## Key Components

### Server (`server/src/main/java/.../UnityCatalogServer.java`)
- Java/Armeria-based HTTP server (not Spring Boot)
- Port 8080, API base path `/api/2.1/unity-catalog/` (line 71)
- Hibernate/JPA for persistence
- JCasbin for RBAC authorization

### AI SDK (`ai/core/src/unitycatalog/ai/core/`)
- `client.py`: `UnitycatalogFunctionClient` — manages and executes UC functions in sandboxed subprocess
- `base.py`: `BaseFunctionClient` abstract base for function clients
- Execution modes: `local`, `local_subprocess` (sandboxed with multiprocessing)
- Supports wrapped functions (multiple helpers inlined into primary function)

### Integrations (`ai/integrations/`)
- Anthropic, LangChain, LangGraph, OpenAI, LlamaIndex, LiteLLM, DSPy, etc.

### Spark Connector (`connectors/spark/src/main/scala/.../UCSingleCatalog.scala`)
- `UCSingleCatalog.scala`: Spark catalog implementation for connecting to UC

## Entry Points

```bash
# Start UC server
bin/start-uc-server

# CLI operations
bin/uc catalog list
bin/uc schema create --catalog unity --schema myschema
bin/uc table get --full_name unity.default.mytable

# Build from source
build/sbt clean package publishLocal

# Create deployment tarball
build/sbt createTarball

# Run tests
build/sbt -J-Xmx2G clean test

# Format code
build/sbt javafmtAll
```

## Configuration

Server reads from `etc/conf/server.properties`:
- `storage-root.tables`: base path for table storage
- `authorization-enabled`: toggle RBAC
- `s3.*`: S3/minio configuration for storage

Python AI SDK (`ai/core/src/unitycatalog/ai/core/client.py`):
- `execution_mode`: `"local"` or `"sandbox"` (default) for function execution
- Configured with `base_url`, `api_key` for the UC server

## Key Technologies

- Java/Armeria server
- Hibernate/JPA persistence
- JCasbin RBAC
- OpenAPI 3.0 (generated from `api/all.yaml`, ~114KB)
- Python AI SDK with sandboxed execution
- Apache Iceberg REST catalog API compatible
- Apache Hive metastore API compatible

---

## Repo-specific gotchas (durable lessons)

These are real bugs/patterns discovered during Maptic work. Each is something a future agent should know before touching the corresponding code.

### DeltaCommitDAO BINARY(16) columns — JPA UUID mapping for PostgreSQL

`DeltaCommitDAO.java` (`server/src/main/java/io/unitycatalog/server/persist/dao/DeltaCommitDAO.java:33,36`) uses `@Column(columnDefinition = "BINARY(16)")` for both `id` and `table_id` UUID fields. This is required for PostgreSQL compatibility — without it, Hibernate may generate incompatible column types that cause commit-tracking failures on managed Delta tables.

**Bug shape:** CREATE MANAGED DELTA TABLE succeeds but INSERT fails with UUID cast error, or commit history queries return empty.

**Live evidence:** The column is at line 33 (`id`) and line 36 (`table_id`) in `DeltaCommitDAO.java`.

### DeltaCommitRepository PostgreSQL DELETE LIMIT fix

`DeltaCommitRepository.java` (`server/src/main/java/io/unitycatalog/server/persist/DeltaCommitRepository.java:697-729`) uses a subquery pattern for batch deletion instead of `DELETE ... LIMIT`, because PostgreSQL does not support `DELETE ... LIMIT` directly (unlike MySQL/H2). The fix wraps the LIMIT in a `DELETE WHERE id IN (SELECT id ... LIMIT N)` subquery.

**Why it matters:** Without this fix, managed Delta commit expiration/pruning fails silently on PostgreSQL, causing unbounded table growth and eventual storage issues.

**The fix is at lines 697-729** (two methods: `deleteCommitsUpTo` and `deleteCommits`).

---

## MAPTIC Fork

We maintain a fork at `MAPTICAI/unitycatalog` on branch `fix/flux-engine-checkout`. Base: upstream `v0.5.0`. Maptic-specific changes (verify against git log in the fork):

| What | Why |
|------|-----|
| Add `org.postgresql:postgresql:42.7.4` to `build.sbt:384` | Maptic runs UC on RDS PostgreSQL, not H2 |
| Copy + chown `/root/.cache` for coursier deps in Docker | Docker build needs coursier cache accessible by `unitycat` user |
| `chmod 755 /root` in Docker | Same — coursier traversal |
| Rewrite `DELETE ... LIMIT N` → subquery in `DeltaCommitRepository.java` | PostgreSQL doesn't support `DELETE ... LIMIT` (MySQL/H2 syntax). Managed Delta commits fail without this. |
| Checkstyle line-wrap for the above | Cosmetic |

**When rebasing onto a new upstream release:**
1. The PostgreSQL JDBC dep may need re-applying if `build.sbt` changes
2. The DELETE LIMIT fix will likely need re-applying until upstream accepts a PR
3. The Docker coursier fixes may become unnecessary if upstream changes their Dockerfile
4. Verify by building the Docker image and running managed Delta table CREATE/INSERT/SELECT against RDS

**Building and pushing a new UC image (Maptic internal):**
```bash
unset GITHUB_TOKEN
gh api repos/MAPTICAI/infrastructure/actions/workflows/276661507/dispatches \
  -X POST \
  -f 'ref=fix/flux-engine-checkout' \
  -f 'inputs[service]=unitycatalog' \
  -f 'inputs[version]=latest' \
  -f 'inputs[source_repo]=MAPTICAI/unitycatalog' \
  -f 'inputs[source_branch]=fix/flux-engine-checkout'
```
Then `kubectl rollout restart deployment/flux-engine-unitycatalog -n maptic`.

## Dependencies in Monorepo

- **FluxEngine** uses Unity Catalog as its governance layer
- The `connectors/spark/src/main/scala/io/unitycatalog/spark/UCSingleCatalog.scala` connects FluxEngine's Spark pods to UC
- FluxEngine can deploy UC as a subchart (`governance.unityCatalog.deployWithChart=true`)

---

## Cross-references

- Workspace-level context: `/Users/apurupreddy/maptic_git/AGENTS.md`
- **Workspace conventions (branch, naming, K8s namespace, commits):** [maptic_cel/conventions/](https://github.com/MAPTICAI/maptic_cel/tree/main/conventions) (single source of truth for workspace-level rules; supersedes any duplicates in per-repo docs)
- Spark compute backend (consumer of UC): `/Users/apurupreddy/maptic_git/FluxEngine/AGENTS.md`
- Agent gateway (calls UC REST API): `/Users/apurupreddy/maptic_git/agent_gateway/AGENTS.md`
- Infrastructure (K8s manifests for UC): `/Users/apurupreddy/maptic_git/infrastructure/AGENTS.md`

## Related knowledge

Workspace-wide context lives in [`maptic_cel/workspace-agents-INDEX.md`](../maptic_cel/workspace-agents-INDEX.md).
Per-topic deep dives live in `maptic_cel/knowledge/`:

- [`fluxengine.md`](../maptic_cel/knowledge/fluxengine.md) — Spark engine + Kyuubi
- [`unitycatalog.md`](../maptic_cel/knowledge/unitycatalog.md) — UC server + Delta paths
- [`agent-gateway.md`](../maptic_cel/knowledge/agent-gateway.md) — Agent runtime, plan approval
- [`llm-gateway.md`](../maptic_cel/knowledge/llm-gateway.md) — LLM routing, SSE streaming
- [`aws-eks.md`](../maptic_cel/knowledge/aws-eks.md) — EKS cluster, Karpenter, IRSA
- [`infra-terraform.md`](../maptic_cel/knowledge/infra-terraform.md) — Terraform state
- [`maptic-cel.md`](../maptic_cel/knowledge/maptic-cel.md) — CEL knowledge layer itself
