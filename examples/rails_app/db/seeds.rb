# frozen_string_literal: true

ActiveRecord::Base.connection_pool.with_connection do |connection|
  load File.expand_path("schema.rb", __dir__) unless connection.data_source_exists?("products")
end
[["Coffee", 450], ["Tea", 300], ["Water", 150]].each do |name, price|
  Product.find_or_create_by!(name:) { |product| product.price_cents = price }
end
