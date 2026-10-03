# Gritz Rails

Rails integration for [Gritz](https://github.com/gritzrpc/gritz): RPC controller loading, generators, complete-RPC execution and single-process development reloading. Requires CRuby 3.3+, Rails 8.0 or 8.1, and Gritz 0.9.0. Runtime dependencies are `gritz-core` and `railties`; applications choose their transport separately.

## Install

```ruby
gem "gritz", "~> 0.9.0"
gem "gritz-rails", "~> 0.9.0"
```

```sh
bin/rails generate gritz:install
# Generate protobufs into lib/protos, then generate a bound controller:
bin/rails generate gritz:controller Greeter SayHello --service Helloworld::Greeter::Service
bin/gritz routes
bin/gritz check
bin/gritz start
```

Implement each generated action using `request.message` or `request.each_message`, and `stream.write` for response streams. The controller generator accepts RPC names and `--service` names; it adds the controller to `config/gritz.rb`. Set `strict_routes true` after all actions are implemented.

## Rails lifecycle

Generated `config/gritz.rb` loads the application through `rails_app`, selects four workers in production and zero elsewhere, and registers controllers. Additional settings come after `rails_app`, including explicit `reflection false` or `true`. Rails development enables Reflection for the Native adapter by default; other environments keep the core's disabled default.

Every complete application RPC runs inside the Rails executor. Development uses the Rails reloader and resolves controller constants after reload. Active Record connections return to their pools, query caches finish and CurrentAttributes reset on successful and failed calls. Application threads created inside a handler must use Rails' own executor wrapping. See the [Rails execution guide](https://guides.rubyonrails.org/threading_and_code_execution.html).

Application code is eager loaded before fork. In prefork mode, all Active Record pools disconnect after eager loading, before Ruby warmup, and again before each fork. Ruby's Rails fork tracking remains active. Development reloading requires `workers 0`; changing protobuf definitions, bound services or registered routes requires a server restart. Production code changes use Gritz's `USR2` fresh-interpreter replacement.

`app/rpc` participates in Rails autoloading and eager loading. Generated protobuf files in `lib/protos` are excluded from both Zeitwerk loaders and required explicitly by the generated initializer. Keep generated files outside normal autoload directories.

For an already initialized application, use `Gritz::Rails.install(config, application: Rails.application)` once before starting the server. Match Active Record pool capacity to RPC concurrency with `RAILS_MAX_THREADS` or your database configuration.

## Async execution

Use `gritz-async` in place of the `gritz` meta gem. In `config/gritz.rb`, require `gritz/async`, set `transport :async` and `listener_strategy :inherited_fd` **before** `rails_app`. Define services with `Gritz::Async::Service` and load only generated `*_pb.rb` messages; generated `*_services_pb.rb` files load the official grpc gem. Start with `bundle exec gritz start -C config/gritz.rb` to use the Async entrypoint.

The integration selects `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber`, isolating CurrentAttributes and executor resources across concurrent RPCs. Use a database driver that supports Fiber Scheduler I/O and size its pool for concurrent database work. Async does not currently serve Reflection or the gRPC Health service; use Gritz's admin readiness endpoint.

## Examples and migration

The [Rails catalog sample](examples/rails_app) serves SQLite-backed unary and streaming RPCs with four production workers. It includes the [memory validation](docs/reports/T5-07-rails-memory.md).

Existing Gruf applications can use the optional `Gritz::Compat::Gruf` controller and interceptor adapter in `gritz-core`. See the [migration guide](https://github.com/gritzrpc/gritz-core/blob/main/docs/guides/migrating-from-gruf.md).

## Development

```sh
bundle install
COVERAGE=1 bundle exec rake
bundle exec rubocop
bundle exec bundler-audit check --update
bundle exec rake build
```

CI tests Ruby 3.3, 3.4 and 4.0 against Rails 8.0 and 8.1. Tests include real RPCs, file-change reloading, all-pool fork cleanup, executable generated configuration and Linux four-worker sample lifecycle. Sibling checkout overrides follow [CONTRIBUTING.md](CONTRIBUTING.md).

Publication uses [Trusted Publishing](docs/guides/releasing.md).

## Documentation

Read the [published guides and API reference](https://gritzrpc.github.io/gritz/), [public API policy](https://github.com/gritzrpc/gritz/blob/main/docs/public-api.md), [support policy](https://github.com/gritzrpc/gritz/blob/main/docs/support-policy.md) and [stabilization gate](https://github.com/gritzrpc/gritz/blob/main/docs/stabilization.md).

## License

[MIT](LICENSE.txt).
