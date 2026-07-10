# CLAUDE.md - unitycatalog

**Unity Catalog OSS** - universal catalog for data and AI assets (Apache 2.0), providing multi-format support, multi-engine access, and unified governance.

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
├── build.sbt                    # Scala build config
├── server/src/main/java/io/unitycatalog/server/
│   ├── UnityCatalogServer.java  # Main entry (port 8080), Armeria server builder
│   ├── URLTranscoderVerticle.java # Backward compatibility port transcoder
│   ├── service/                 # Business logic: CatalogService, SchemaService, TableService, etc.
│   ├── persist/                 # Hibernate/JPA repositories and DAOs
│   ├── auth/                    # JCasbinAuthorizer, AllowingAuthorizer, security decorators
│   └── security/               # JwtToken, SecurityConfiguration, SecurityContext
├── api/
│   ├── all.yaml                 # OpenAPI 3.0 spec (~110KB) — generated models/controllers
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
├── connectors/spark/            # UCSingleCatalog Scala connector for Spark
├── ui/                         # React UI
├── helm/                        # Kubernetes Helm chart
├── bin/
│   ├── start-uc-server         # Start UC server script
│   └── uc                       # CLI tool
└── docs/
```

## Key Components

### Server (`server/src/main/java/.../UnityCatalogServer.java`)
- Java/Armeria-based HTTP server (not Spring Boot)
- Port 8080, API base path `/api/2.1/unity-catalog/`
- Hibernate/JPA for persistence
- JCasbin for RBAC authorization

### AI SDK (`ai/core/`)
- `UnitycatalogFunctionClient`: manages and executes UC functions in sandboxed subprocess
- `BaseFunctionClient`: abstract base for function clients
- Execution modes: `local`, `local_subprocess` (sandboxed with multiprocessing)
- Supports wrapped functions (multiple helpers inlined into primary function)

### Integrations (`ai/integrations/`)
- Anthropic, LangChain, LangGraph, OpenAI, LlamaIndex, LiteLLM, DSPy, etc.

### Spark Connector (`connectors/spark/`)
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

Python AI SDK (`ai/core/client.py`):
- `execution_mode`: `"local"` or `"sandbox"` (default) for function execution
- Configured with `base_url`, `api_key` for the UC server

## Key Technologies

- Java/Armeria server
- Hibernate/JPA persistence
- JCasbin RBAC
- OpenAPI 3.0 (generated from `api/all.yaml`)
- Python AI SDK with sandboxed execution
- Apache Iceberg REST catalog API compatible
- Apache Hive metastore API compatible

## MAPTIC Fork

We maintain a fork at `MAPTICAI/unitycatalog` on branch `fix/flux-engine-checkout`. Base: upstream `v0.5.0`. We carry **5 commits** beyond upstream:

| Commit | What | Why |
|--------|------|-----|
| `6dd77db1` | Add `org.postgresql:postgresql:42.7.4` to `build.sbt` | We run UC on RDS PostgreSQL, not H2 |
| `291876aa` | Copy + chown `/root/.cache` for coursier deps in Docker | Docker build needs coursier cache accessible by `unitycat` user |
| `601e59fb` | `chmod 755 /root` in Docker | Same — coursier traversal |
| `0ed06621` | Rewrite `DELETE ... LIMIT N` → subquery in `DeltaCommitRepository.java` | PostgreSQL doesn't support `DELETE ... LIMIT` (MySQL/H2 syntax). Managed Delta commits fail without this. |
| `02c4ca99` | Checkstyle line-wrap for the above | Cosmetic |

**When rebasing onto a new upstream release:**
1. The PostgreSQL JDBC dep may need re-applying if `build.sbt` changes
2. The DELETE LIMIT fix will likely need re-applying until upstream accepts a PR
3. The Docker coursier fixes may become unnecessary if upstream changes their Dockerfile
4. Verify by building the Docker image and running managed Delta table CREATE/INSERT/SELECT against RDS

**Building and pushing a new UC image:**
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
- The `connectors/spark/UCSingleCatalog.scala` connects FluxEngine's Spark pods to UC
- FluxEngine can deploy UC as a subchart (`governance.unityCatalog.deployWithChart=true`)
