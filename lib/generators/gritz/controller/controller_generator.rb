# frozen_string_literal: true

require "rails/generators/named_base"

module Gritz
  module Generators
    # Generates a controller bound to an application's generated service.
    # @api public
    class ControllerGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      desc "Generate an RPC controller and register it in config/gritz.rb."
      argument :actions, type: :array, default: [], banner: "RPC_ACTIONS"
      class_option :service, type: :string, desc: "Generated service class (defaults to NAME::Service)"

      def create_controller
        raise Thor::Error, "service must be a Ruby constant name" unless /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/.match?(service_class_name)
        unless actions.all? { |action| /\A[a-z_]\w*\z/.match?(action.underscore) }
          raise Thor::Error, "action must be a Ruby method name"
        end

        template "controller.rb.tt", "app/rpc/#{file_path}_controller.rb"
        append_to_file "config/gritz.rb", "\nregister_controller #{class_name}Controller\n"
      end

      private

      def service_class_name
        (options[:service] || "#{class_name}::Service").delete_prefix("::")
      end
    end
  end
end
