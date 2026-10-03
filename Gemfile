# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "railties", ENV["RAILS_VERSION"] if ENV["RAILS_VERSION"]

unless ENV["GRITZ_RELEASE"] == "1"
  gem "gritz-core", git: "https://github.com/gritzrpc/gritz-core.git", branch: "main"
  gem "gritz-native", git: "https://github.com/gritzrpc/gritz-native.git", branch: "main"
end

group :development, :test do
  gem "activerecord", ENV.fetch("RAILS_VERSION", ">= 8.0"), "< 9"
  gem "bundler-audit", "~> 0.9"
  gem "gritz-native", "= 0.6.0" if ENV["GRITZ_RELEASE"] == "1" # rubocop:disable Bundler/DuplicatedGem -- Source dependencies are disabled for releases.
  gem "grpc-tools", "~> 1.83"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.75"
  gem "simplecov", "~> 0.22.0"
  gem "sqlite3", ">= 2.9.6", "< 3"
  gem "yard", "~> 0.9"
end
