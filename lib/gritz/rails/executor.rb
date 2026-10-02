# frozen_string_literal: true

module Gritz
  module Rails
    # Keeps Rails resources and reload interlocks scoped to the entire RPC.
    # @api public
    class Executor
      def initialize(app, application:, development: false)
        @app = app
        @executor = development ? application.reloader : application.executor
      end

      def call(context)
        @executor.wrap { @app.call(context) }
      end
    end
  end
end
