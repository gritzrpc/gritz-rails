# frozen_string_literal: true

class ProductsController < Gritz::Controller
  bind Catalog::Products::Service
  before_action { Current.request_id = context.request_id }
  rescue_from ActiveRecord::RecordNotFound do
    fail!(:not_found, "product not found")
  end

  def get_product # rubocop:disable Naming/AccessorMethodName -- Generated RPC action.
    fail!(:invalid_argument, "id must be positive") unless request.message.id.positive?
    reply(Product.find(request.message.id))
  end

  def list_products
    limit = request.message.limit
    fail!(:invalid_argument, "limit must be between 1 and 100") unless limit.between?(1, 100)
    Product.order(:id).limit(limit).each { |product| stream.write(reply(product)) }
  end

  private

  def reply(product)
    Catalog::ProductReply.new(id: product.id, name: product.name, price_cents: product.price_cents,
                              worker_pid: Process.pid, request_id: Current.request_id.to_s)
  end
end
