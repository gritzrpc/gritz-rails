# frozen_string_literal: true

require_relative "lib/gritz/rails/version"

Gem::Specification.new do |spec|
  spec.name = "gritz-rails"
  spec.version = Gritz::Rails::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Rails integration for Gritz RPC servers"
  spec.description = "Rails autoloading, RPC execution, generators and safe preloading for Gritz."
  spec.homepage = "https://github.com/gritzrpc/gritz-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "homepage_uri" => "#{spec.homepage}/",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"] }
  spec.require_paths = ["lib"]
  spec.add_dependency "gritz-core", "= 0.5.0"
  spec.add_dependency "railties", ">= 8.0", "< 9"
end
