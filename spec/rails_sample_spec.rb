# frozen_string_literal: true

require "spec_helper"
require "gritz/native"
require "socket"
require "tmpdir"

RSpec.describe "Rails ActiveRecord sample", skip: RUBY_PLATFORM.include?("linux") ? false : "native prefork requires Linux" do
  it "serves database records from all four workers and shuts down every owned process" do
    sample = File.expand_path("../examples/rails_app", __dir__)
    expect(File.file?(File.join(sample, "config/gritz.rb"))).to be(true), "sample RPC configuration is missing"
    $LOAD_PATH.unshift(File.join(sample, "lib/protos"))
    require "catalog_services_pb"
    Dir.mktmpdir("gritz-rails-sample") do |directory|
      address = free_address
      cluster = Gritz::Testing::Cluster.new(config_path: File.join(sample, "config/gritz.rb"),
                                            env: { "RAILS_ENV" => "production", "GRITZ_WORKERS" => "4", "GRITZ_BIND" => address,
                                                   "GRITZ_ADMIN_BIND" => free_address, "CATALOG_DATABASE" => File.join(directory, "catalog.sqlite3"),
                                                   "CATALOG_AUTO_SEED" => "1", "GRITZ_DRAIN_DELAY" => "0", "GRITZ_SHUTDOWN_TIMEOUT" => "3" })
      channels = []
      begin
        cluster.start.wait_until(workers: 4, timeout: 45)
        expected = cluster.workers.map { |worker| worker.fetch(:pid) }.sort
        seen = []
        64.times do
          channel = GRPC::Core::Channel.new(address, { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }, :this_channel_is_insecure)
          channels << channel
          client = Catalog::Products::Stub.new(address, :this_channel_is_insecure, channel_override: channel)
          response = client.get_product(Catalog::ProductRequest.new(id: 1), metadata: { "x-request-id" => "catalog-check" }, deadline: Time.now + 3)
          expect(response).to have_attributes(id: 1, name: "Coffee", request_id: "catalog-check")
          seen << response.worker_pid
          rows = client.list_products(Catalog::ListRequest.new(limit: 2), deadline: Time.now + 3).to_a
          expect(rows.map(&:name)).to eq(%w[Coffee Tea])
          expect { client.get_product(Catalog::ProductRequest.new(id: 0), deadline: Time.now + 3) }.to raise_error(GRPC::InvalidArgument)
          break if seen.uniq.sort == expected
        end
        expect(seen.uniq.sort).to eq(expected)
        owned = [cluster.pid, cluster.master_pid, *expected].uniq
      ensure
        channels.each(&:close)
        cluster.stop(timeout: 5)
      end
      expect(cluster.wait).to be_success
      owned.each { |pid| expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) }
    end
  end

  def free_address
    listener = TCPServer.new("127.0.0.1", 0)
    "127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
  end
end
