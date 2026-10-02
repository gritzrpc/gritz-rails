# frozen_string_literal: true

ActiveRecord::Schema[8.0].define(version: 1) do
  create_table :products, force: true do |t|
    t.string :name, null: false
    t.integer :price_cents, null: false
  end
end
