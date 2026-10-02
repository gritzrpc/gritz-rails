# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  # Gritz's preloader eagerly loads application code before forking.
  config.eager_load = false
  config.consider_all_requests_local = false
  config.logger = Logger.new($stdout)
  config.log_level = :warn
  config.active_record.dump_schema_after_migration = false
end
