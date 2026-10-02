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

On CRuby 3.4 and later, this sample opts in to minor collections through `before_fork`, after Gritz calls `Process.warmup`. This preserves warmed pages shared by the master and workers. Minor GC remains active, but automatic major collections and young-to-old promotion stop: old garbage can remain and the heap can grow. Use the existing `worker_recycle` limits to bound worker lifetime or memory in production, and `USR2` to replace the master when needed. Remove the hook for ordinary GC. Single-process mode, Ruby 3.3, the Rails integration itself and generated configurations keep Ruby's defaults. See [Ruby's GC configuration](https://docs.ruby-lang.org/en/3.4/GC.html#method-c-config).

The database defaults to `storage/catalog.sqlite3`. Override `CATALOG_DATABASE` for a separate database and `RAILS_MAX_THREADS` for pool capacity (default16, matching Gritz threads). `CATALOG_AUTO_SEED=1` is used only by isolated test/benchmark databases; normal setup uses `db:prepare`.

The Linux integration test exercises records, streaming, validation errors and every worker, then checks every owned PID exited. The [memory report](../../docs/reports/T5-07-rails-memory.md) compares loaded single-process RSS with marginal prefork PSS, and records no eager preload, eager preload and eager preload plus Ruby warmup.
