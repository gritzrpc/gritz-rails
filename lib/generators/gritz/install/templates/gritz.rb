# frozen_string_literal: true

require "gritz/rails"

rails_app
workers ::Rails.env.production? ? 4 : 0 # rubocop:disable Style/RedundantConstantBase -- The config is evaluated inside Gritz::DSL.
threads 16

# Add controllers with: bin/rails generate gritz:controller Greeter SayHello --service Example::Greeter::Service
