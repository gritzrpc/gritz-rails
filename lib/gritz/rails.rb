# frozen_string_literal: true

require "gritz/core"
require "rails"
require "active_support/fork_tracker"
require_relative "rails/version"
require_relative "rails/executor"
require_relative "rails/railtie"

module Gritz
  module Rails
    # Installs Rails execution and fork lifecycle hooks into one server configuration.
    # @api public
    def self.install(config, application: ::Rails.application)
      raise ConfigurationError, "rails_app requires an initialized Rails application" unless application&.initialized?

      installed = config.middleware.entries.find { |entry| entry.middleware == Executor }
      if installed
        raise ConfigurationError, "Rails integration is already installed for another application" unless installed.options[:application].equal?(application)

        return config
      end

      development = ::Rails.env.development?
      config.reflection = true if development
      first = config.middleware.entries.first
      if first
        config.middleware.insert_before(first.middleware, Executor, application:, development:)
      else
        config.middleware.use(Executor, application:, development:)
      end
      disconnect_pools = lambda do |_index = nil|
        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.connection_handler.connection_pool_list(:all).each(&:disconnect!)
        end
      end
      config.add_preloader do
        raise ConfigurationError, "Rails development mode requires workers 0" if development && config.workers.positive?

        application.eager_load!
        config.controllers.map! { |controller| reloadable_controller(controller) } if development
        disconnect_pools.call if config.workers.positive?
      end
      config.add_hook(:before_fork, &disconnect_pools)
      config
    end

    # Route descriptors stay fixed, while the controller constant is resolved after Rails reloads.
    # @api private
    def self.reloadable_controller(controller)
      name = controller.name
      raise ConfigurationError, "Rails development mode requires a named controller" unless name

      Class.new(Gritz::Controller) do
        bind controller.service_class
        define_singleton_method(:name) { name }
        define_singleton_method(:to_s) { name }
        define_singleton_method(:action_defined?) { |action| name.constantize.action_defined?(action) }
        define_singleton_method(:new) { |**options| name.constantize.new(**options) }
      end
    end

    # @api public
    module ConfigurationDSL
      def rails_app(path = "config/environment.rb")
        require File.expand_path(path)
        Gritz::Rails.install(@config)
      end
    end
  end
end

Gritz::DSL.include(Gritz::Rails::ConfigurationDSL)
