# frozen_string_literal: true

require "rails/generators"

module Gritz
  module Generators
    # Creates the configuration and binstub for a Rails RPC server.
    # @api public
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Install Gritz configuration, protobuf loading, and bin/gritz."

      def install
        template "gritz.rb", "config/gritz.rb"
        copy_file "initializer.rb", "config/initializers/gritz.rb"
        copy_file "gritz", "bin/gritz"
        chmod "bin/gritz", 0o755
        empty_directory "lib/protos"
        create_file "lib/protos/.keep"
        empty_directory "app/rpc"
        create_file "app/rpc/.keep"
      end
    end
  end
end
