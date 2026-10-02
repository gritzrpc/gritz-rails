# Rails catalog RPC sample

Generated with Rails 8.1 `rails new --api --minimal`, then configured for Rails 8.0/8.1 defaults and Gritz. Products are stored in SQLite; unary `GetProduct` reads one row, and `ListProducts` streams a bounded list. Responses include the worker PID and request ID for inspection.

```sh
bundle install
bundle exec rails db:prepare
bundle exec ruby bin/gritz check
bundle exec ruby bin/gritz start
```

Development runs one process (`workers 0`), reloads controllers/models and enables Reflection. From another terminal:

```sh
grpcurl -plaintext -d '{"id":"1"}' localhost:50051 catalog.Products/GetProduct
grpcurl -plaintext -d '{"limit":2}' localhost:50051 catalog.Products/ListProducts
```

For four production workers on Linux:

```sh
RAILS_ENV=production bundle exec rails db:prepare
RAILS_ENV=production bundle exec ruby bin/gritz check
RAILS_ENV=production bundle exec ruby bin/gritz start
```

Production Reflection is disabled. Supply `-import-path lib/protos -proto catalog.proto` to grpcurl, or explicitly enable `reflection true` in `config/gritz.rb` for a controlled environment.

The database defaults to `storage/catalog.sqlite3`. Override `CATALOG_DATABASE` for a separate database and `RAILS_MAX_THREADS` for pool capacity (default16, matching Gritz threads). `CATALOG_AUTO_SEED=1` is used only by isolated test/benchmark databases; normal setup uses `db:prepare`.

The Linux integration test exercises records, streaming, validation errors and every worker, then checks every owned PID exited. The [memory report](../../docs/reports/T5-07-rails-memory.md) compares loaded single-process RSS with marginal prefork PSS, and records no eager preload, eager preload and eager preload plus Ruby warmup.
