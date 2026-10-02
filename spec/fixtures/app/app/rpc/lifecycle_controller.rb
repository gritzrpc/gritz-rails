# frozen_string_literal: true

class LifecycleController < Gritz::Controller
  bind RailsRpc::Lifecycle::Service

  def unary
    touch_database(request.message.value)
    RailsRpc::Response.new(value: "original")
  end

  def upload
    values = request.messages.map(&:value)
    touch_database(values.join)
    RailsRpc::Response.new(value: values.join)
  end

  def download
    touch_database(request.message.value)
    2.times { stream.write(RailsRpc::Response.new(value: Widget.count.to_s)) }
  end

  def chat
    request.messages.each do |message|
      touch_database(message.value)
      stream.write(RailsRpc::Response.new(value: Widget.count.to_s))
    end
  end

  private

  def touch_database(value)
    raise "CurrentAttributes leaked" unless Current.value.nil?
    raise "query cache not enabled" unless Widget.connection_pool.query_cache_enabled

    Current.value = value
    Widget.lease_connection
    Widget.count
    raise "controller failed" if value == "error"
  end
end
