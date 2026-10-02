# frozen_string_literal: true

require "tmpdir"
require "open3"
require "generators/gritz/install/install_generator"
require "generators/gritz/controller/controller_generator"

RSpec.describe "Rails generators" do
  around do |example|
    Dir.mktmpdir("gritz-generator") do |root|
      @root = root
      example.run
    end
  end

  def generate(generator, arguments = [])
    generator.start([*arguments, "--quiet"], destination_root: @root, shell: Thor::Shell::Basic.new, debug: true)
  end

  it "generates runnable configuration, protobuf initializer and executable binstub" do
    generate(Gritz::Generators::InstallGenerator)
    expect(File.read("#{@root}/config/gritz.rb")).to include("rails_app", "workers")
    expect(File.read("#{@root}/config/initializers/gritz.rb")).to include("lib/protos/**/*_pb.rb", "require path")
    expect(File.stat("#{@root}/bin/gritz").mode & 0o111).to eq(0o111)
    expect(File.read("#{@root}/bin/gritz")).to include("Gritz::CLI.new(launch: true)")
    %w[lib/protos/.keep app/rpc/.keep].each { |path| expect(File).to exist("#{@root}/#{path}") }
    RubyVM::InstructionSequence.compile_file("#{@root}/config/gritz.rb")
    RubyVM::InstructionSequence.compile_file("#{@root}/config/initializers/gritz.rb")
  end

  it "generates namespaced controller actions bound to an explicit service and registers the controller" do
    generate(Gritz::Generators::InstallGenerator)
    generate(Gritz::Generators::ControllerGenerator, ["admin/Greeter", "SayHello", "HTTPStatus", "--service", "Example::Greeter::Service"])
    path = "#{@root}/app/rpc/admin/greeter_controller.rb"
    content = File.read(path)
    expect(content).to include("class Admin::GreeterController < Gritz::Controller", "bind ::Example::Greeter::Service", "def say_hello", "def http_status")
    expect(File.read("#{@root}/config/gritz.rb")).to include("register_controller Admin::GreeterController")
    RubyVM::InstructionSequence.compile_file(path)
  end

  it "defaults the service namespace to the controller name" do
    generate(Gritz::Generators::InstallGenerator)
    generate(Gritz::Generators::ControllerGenerator, ["Greeter"])
    expect(File.read("#{@root}/app/rpc/greeter_controller.rb")).to include("bind ::Greeter::Service")
  end

  it "rejects invalid service and action names before generating files" do
    generate(Gritz::Generators::InstallGenerator)
    expect { generate(Gritz::Generators::ControllerGenerator, ["Greeter", "--service", "not a constant"]) }.to raise_error(Thor::Error, /service/)
    expect { generate(Gritz::Generators::ControllerGenerator, ["Greeter", "not an action"]) }.to raise_error(Thor::Error, /action/)
    expect(File).not_to exist("#{@root}/app/rpc/greeter_controller.rb")
  end

  it "evaluates generated configuration through the real DSL in a booted Rails application" do
    generate(Gritz::Generators::InstallGenerator)
    File.write("#{@root}/config/environment.rb", <<~RUBY)
      require "gritz/rails"
      module GeneratedApp
        class Application < ::Rails::Application
          config.root = File.expand_path("..", __dir__)
          config.eager_load = false
          config.enable_reloading = false
          config.secret_key_base = "s" * 64
          config.logger = Logger.new(File::NULL)
        end
      end
      ::Rails.application.initialize!
    RUBY
    output, status = Open3.capture2e({ "RAILS_ENV" => "production" }, RbConfig.ruby,
                                     "-I", File.expand_path("../lib", __dir__), "-e", <<~RUBY, chdir: @root)
                                       require "gritz/rails"
                                       config = Gritz::Configuration.load(path: "config/gritz.rb", env: {})
                                       abort "wrong workers" unless config.workers == 4
                                       abort "not preloaded" unless config.preload_app?
                                       config.preload!
                                     RUBY
    expect(status.success?).to be(true), output
  end
end
