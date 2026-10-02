# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "gritz/native"
require "active_record/railtie"

RSpec.describe "Rails integration" do
  before(:all) do
    @root = Dir.mktmpdir("gritz-rails-spec")
    FileUtils.cp_r("#{__dir__}/fixtures/app/.", @root)
    FileUtils.mkdir_p("#{@root}/lib/protos")
    FileUtils.cp_r("#{__dir__}/fixtures/protos/.", "#{@root}/lib/protos")
    Rails.env = "development"
    @application = Class.new(Rails::Application) do
      config.eager_load = false
      config.enable_reloading = true
      config.reload_classes_only_on_change = true
      config.secret_key_base = "s" * 64
      config.logger = Logger.new(File::NULL)
      config.file_watcher = ActiveSupport::FileUpdateChecker
    end
    @application.config.root = @root
    @application.config.autoload_lib(ignore: [])
    @application.initialize!
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "#{@root}/database.sqlite3", pool: 4)
    ActiveRecord::Schema.define { create_table(:widgets) { |table| table.string :value } }
    ActiveRecord::Base.connection_pool.release_connection
  end

  after(:all) do
    ActiveRecord::Base.connection_handler.connection_pool_list(:all).each(&:disconnect!)
    FileUtils.remove_entry(@root)
  end

  def configuration
    Gritz::Configuration.new.tap do |settings|
      settings.bind = "127.0.0.1:0"
      settings.controllers = [LifecycleController]
      settings.shutdown_timeout = 1
      Gritz::Rails.install(settings, application: @application.instance)
    end
  end

  it "autoloads app/rpc and excludes explicitly required protobuf files from Zeitwerk" do
    expect(LifecycleController).to be < Gritz::Controller
    expect { @application.eager_load! }.not_to raise_error
    expect(Rails.autoloaders.main.dirs).to include("#{@root}/app/rpc")
    expect(Rails.autoloaders.main.cpath_expected_at("#{@root}/lib/protos/lifecycle_pb.rb")).to be_nil
    expect(configuration.reflection).to be(true)
  end

  it "installs once and preserves explicit settings made after rails_app" do
    config = configuration
    Gritz::Rails.install(config, application: @application.instance)
    expect(config.middleware.entries.count { |entry| entry.middleware == Gritz::Rails::Executor }).to eq(1)
    config.reflection = false
    config.preload!
    expect(config.reflection).to be(false)
    expect(Gritz::Router.new(controllers: config.controllers).routes.values.map { |route| route.controller.to_s }.uniq).to eq(["LifecycleController"])
  end

  it "returns leased connections, resets CurrentAttributes and disables query caching after every RPC and failure" do
    config = configuration
    Gritz::Testing::Server.start(config) do |server|
      stub = RailsRpc::Lifecycle::Stub.new(server.address, :this_channel_is_insecure)
      request = RailsRpc::Request.new(value: "ok")
      expect(stub.unary(request).value).to eq("original")
      expect(stub.upload([request].each).value).to eq("ok")
      expect(stub.download(request).to_a.size).to eq(2)
      expect(stub.chat([request].each).to_a.size).to eq(1)
      error = RailsRpc::Request.new(value: "error")
      [-> { stub.unary(error) }, -> { stub.upload([error].each) },
       -> { stub.download(error).to_a }, -> { stub.chat([error].each).to_a }].each do |invoke|
        expect { invoke.call }.to raise_error(GRPC::Internal)
        expect(Widget.connection_pool.stat[:busy]).to eq(0)
      end
      expect(stub.unary(request).value).to eq("original")
      expect(Widget.connection_pool.stat[:busy]).to eq(0)
      expect(Current.value).to be_nil
    end
  end

  it "reloads controller source through the same running server and does not retain a stale class" do
    config = configuration
    path = "#{@root}/app/rpc/lifecycle_controller.rb"
    original = File.read(path)
    Gritz::Testing::Server.start(config) do |server|
      stub = RailsRpc::Lifecycle::Stub.new(server.address, :this_channel_is_insecure)
      request = RailsRpc::Request.new(value: "ok")
      previous = LifecycleController
      expect(stub.unary(request).value).to eq("original")
      File.write(path, original.sub('value: "original"', 'value: "reloaded"'))
      expect(stub.unary(request).value).to eq("reloaded")
      expect(LifecycleController).not_to equal(previous)
      expect { stub.unary(RailsRpc::Request.new(value: "error")) }.to raise_error(GRPC::Internal)
      expect(Widget.connection_pool.stat[:busy]).to eq(0)
    end
  ensure
    File.write(path, original) if original
    @application.reloader.reload!
  end

  it "rejects reloading with forked workers before starting them" do
    config = configuration
    config.workers = 2
    expect { config.preload! }.to raise_error(Gritz::ConfigurationError, /workers 0/)
  end

  it "disconnects every Active Record pool before fork, including secondary databases" do
    secondary = Class.new(ActiveRecord::Base)
    Object.const_set(:SecondaryRecord, secondary)
    secondary.abstract_class = true
    secondary.establish_connection(adapter: "sqlite3", database: "#{@root}/secondary.sqlite3")
    pools = ActiveRecord::Base.connection_handler.connection_pool_list(:all)
    pools.each(&:lease_connection)
    config = configuration
    config.run_hooks(:before_fork, 0)
    expect(pools.map(&:connected?)).to all(be(false))
    expect(Process.singleton_class.ancestors).to include(ActiveSupport::ForkTracker::CoreExt)
  ensure
    secondary&.remove_connection
    Object.send(:remove_const, :SecondaryRecord) if Object.const_defined?(:SecondaryRecord)
  end

  it "rejects anonymous controllers in development instead of serving stale code" do
    config = configuration
    config.controllers = [Class.new(LifecycleController)]
    expect { config.preload! }.to raise_error(Gritz::ConfigurationError, /named controller/)
  end

  it "uses Rails executor in production, allows prefork and leaves reflection disabled by default" do
    Rails.env = "production"
    config = configuration
    config.workers = 4
    controller = config.controllers.first
    config.preload!
    expect(config.controllers.first).to equal(controller)
    expect(config.reflection).to be(false)
    expect(config.middleware.entries.first.options[:development]).to be(false)
  ensure
    Rails.env = "development"
  end

  it "disables the query cache and clears CurrentAttributes even when application code raises" do
    observed = Thread.new do
      middleware = Gritz::Rails::Executor.new(lambda { |_context|
        Current.value = "request"
        Widget.lease_connection
        raise "cache disabled inside RPC" unless Widget.connection_pool.query_cache_enabled

        raise "request failed"
      }, application: @application.instance)
      begin
        middleware.call(nil)
      rescue RuntimeError => e
        [e.message, Current.value, Widget.connection_pool.query_cache_enabled, Widget.connection_pool.active_connection?]
      end
    end.value
    expect(observed).to eq(["request failed", nil, false, nil])
  end

  it "requires an initialized Rails application" do
    expect { Gritz::Rails.install(Gritz::Configuration.new, application: nil) }.to raise_error(Gritz::ConfigurationError, /initialized/)
  end

  it "installs through rails_app and also supports an empty middleware stack" do
    path = "#{@root}/config/environment.rb"
    File.write(path, "::Rails.application.initialize! unless ::Rails.application.initialized?\n")
    config = Gritz::Configuration.new
    config.middleware = Gritz::Middleware::Stack.new
    Gritz::DSL.new(config).rails_app(path)
    expect(config.middleware.entries.map(&:middleware)).to eq([Gritz::Rails::Executor])
    expect(config.preload_app?).to be(true)
    expect { Gritz::Rails.install(config, application: @application.instance.dup) }.to raise_error(Gritz::ConfigurationError, /another application/)
  end
end
