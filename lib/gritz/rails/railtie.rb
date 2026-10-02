# frozen_string_literal: true

module Gritz
  module Rails
    # Adds RPC controllers to Rails loading while keeping protoc output explicit.
    # @api private
    class Railtie < ::Rails::Railtie
      initializer "gritz.paths", before: :set_autoload_paths do |application|
        application.config.paths.add("app/rpc", eager_load: true)
        application.autoloaders.each { |loader| loader.ignore(application.root.join("lib/protos")) }
      end
    end
  end
end
