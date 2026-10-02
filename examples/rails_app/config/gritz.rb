# frozen_string_literal: true

require "gritz/rails"
rails_app File.expand_path("environment.rb", __dir__)
workers ::Rails.env.production? ? 4 : 0 # rubocop:disable Style/RedundantConstantBase -- Evaluated inside Gritz::DSL.
threads 16
bind "127.0.0.1:50051"
admin_bind "127.0.0.1:9090"
register_controller ProductsController
strict_routes true

# Keep warmed pages shared; this sample opts in to minor GC for prefork processes.
# See the sample README for collection and process replacement tradeoffs.
before_fork do
  GC.config(rgengc_allow_full_mark: false) if GC.respond_to?(:config)
end

# Used only by the isolated integration tests and benchmark databases.
require_relative "../db/seeds" if ENV["CATALOG_AUTO_SEED"] == "1"
