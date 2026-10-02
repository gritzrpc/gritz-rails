# frozen_string_literal: true

# Run on Linux: bundle exec ruby tools/check_rails_memory.rb [seconds per case] [output.json]
require "gritz/rails"
require "gritz/native"
require "json"
require "socket"
require "tmpdir"
require "rbconfig"
require "fileutils"
require "time"
require "digest"
require "etc"

abort "Linux /proc is required" unless RUBY_PLATFORM.include?("linux")
duration = Integer(ARGV.fetch(0, "600"))
abort "duration must be positive" unless duration.positive?
output_path = ARGV.fetch(1, "tmp/rails-memory.json")
sample = File.expand_path("../examples/rails_app", __dir__)
$LOAD_PATH.unshift(File.join(sample, "lib/protos"))
require "catalog_services_pb"

def free_address
  socket = TCPServer.new("127.0.0.1", 0)
  "127.0.0.1:#{socket.addr[1]}"
ensure
  socket&.close
end

def memory(pid)
  data = File.read("/proc/#{pid}/smaps_rollup")
  { pid:, rss_bytes: Integer(data[/^Rss:\s+(\d+)/, 1]) * 1024,
    pss_bytes: Integer(data[/^Pss:\s+(\d+)/, 1]) * 1024,
    uss_bytes: data.scan(/^Private_(?:Clean|Dirty):\s+(\d+)/).sum { |row| Integer(row[0]) } * 1024 }
end

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def median(values) = values.sort.fetch(values.size / 2)

cases = [["single", 0, true, false], ["no_eager_preload", 4, false, false],
         ["preload", 4, true, false], *1.upto(4).map { |count| ["preload_warmup_#{count}", count, true, true] }]
results = []
$stdout.sync = true
source_paths = [__FILE__, *Dir[File.join(sample, "{app,config,db,lib}", "**", "*.{rb,proto,yml}")],
                *Dir[File.expand_path("../lib/gritz/**/*.rb", __dir__)],
                File.expand_path("../../gritz-core/lib/gritz/supervisor/master.rb", __dir__),
                File.expand_path("../../gritz-core/lib/gritz/worker/runner.rb", __dir__)].map { |path| File.expand_path(path) }.sort
workspace = File.expand_path("../..", __dir__)
source_hashes = source_paths.to_h { |path| [path.delete_prefix("#{workspace}/"), Digest::SHA256.file(path).hexdigest] }
report = { started_at: Time.now.utc.iso8601, ruby: RUBY_DESCRIPTION, rails: Gem.loaded_specs.fetch("railties").version.to_s,
           active_record: Gem.loaded_specs.fetch("activerecord").version.to_s, sqlite3: Gem.loaded_specs.fetch("sqlite3").version.to_s,
           grpc: Gem.loaded_specs.fetch("grpc").version.to_s, kernel: File.read("/proc/version").strip,
           duration_per_case: duration, sequential: true, cpu_count: Etc.nprocessors,
           mem_total_kib: Integer(File.read("/proc/meminfo")[/^MemTotal:\s+(\d+)/, 1]),
           load: { target_requests_per_second: 100, client_threads: 4, channels: 32, server_threads_per_worker: 16, rpc_deadline_seconds: 2 },
           source_sha256: source_hashes, conditions: results, complete: false }
FileUtils.mkdir_p(File.dirname(output_path))
Dir.mktmpdir("gritz-rails-memory") do |directory|
  cases.each do |name, count, eager_preload, warmup|
    source_paths.each do |path|
      raise "benchmark source changed: #{path}" unless source_hashes.fetch(path.delete_prefix("#{workspace}/")) == Digest::SHA256.file(path).hexdigest
    end
    puts JSON.generate(event: "starting", name:, workers: count, duration_seconds: duration, at: Time.now.utc.iso8601)
    config_path = File.join(directory, "#{name}.rb")
    application_config = File.join(sample, "config/gritz.rb")
    config_source = "instance_eval(File.read(#{application_config.inspect}), #{application_config.inspect})\n"
    # The no-preload case retains initialized Rails, then eagerly loads application code in workers.
    config_source += "@config.preload_app = false\n" unless eager_preload
    File.write(config_path, config_source)
    address = free_address
    env = { "RAILS_ENV" => "production", "GRITZ_WORKERS" => count.to_s, "GRITZ_THREADS" => "16", "GRITZ_BIND" => address,
            "GRITZ_ADMIN_BIND" => free_address, "GRITZ_DRAIN_DELAY" => "0", "GRITZ_SHUTDOWN_TIMEOUT" => "3",
            "CATALOG_DATABASE" => File.join(directory, "#{name}.sqlite3"), "CATALOG_AUTO_SEED" => "1",
            "CATALOG_WARMUP" => warmup.to_s }
    # Isolate Process.warmup comparison without adding a production setting.
    boot = 'Process.define_singleton_method(:warmup) {} if ENV["CATALOG_WARMUP"] == "false"; exit Gritz::CLI.new(status_io: IO.for_fd(3)).run(ARGV)'
    command = [RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-rgritz/core", "-e", boot, "--", "start", "-C", config_path]
    cluster = Gritz::Testing::Cluster.new(config_path:, env:, command: count.zero? ? nil : command)
    channels = []
    begin
      cluster.start.wait_until(workers: [count, 1].max, timeout: 45)
      worker_pids = cluster.workers.map { |worker| worker.fetch(:pid) }
      owned = [cluster.pid, cluster.master_pid, *worker_pids].uniq
      puts JSON.generate(event: "ready", name:, owner_pid: cluster.pid, master_pid: cluster.master_pid, worker_pids:, at: Time.now.utc.iso8601)
      requests = errors = 0
      error_examples = []
      served = Hash.new(0)
      lock = Mutex.new
      clients = 32.times.map do
        channel = GRPC::Core::Channel.new(address, { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }, :this_channel_is_insecure)
        channels << channel
        Catalog::Products::Stub.new(address, :this_channel_is_insecure, channel_override: channel)
      end
      started = monotonic
      threads = 4.times.map do |index|
        Thread.new do
          sequence = 0
          loop do
            break if monotonic - started >= duration

            client = clients[(index + (sequence * 4)) % clients.size]
            begin
              reply = client.get_product(Catalog::ProductRequest.new(id: (sequence % 3) + 1), deadline: Time.now + 2)
              raise "wrong database response" unless reply.name == %w[Coffee Tea Water].fetch(sequence % 3) && reply.id == (sequence % 3) + 1

              lock.synchronize {
                requests += 1
                served[reply.worker_pid] += 1
              }
            rescue StandardError => e
              lock.synchronize do
                errors += 1
                error_examples << [e.class.name, e.message] if error_examples.size < 10
              end
            end
            sequence += 1
            sleep([started + (sequence * 0.04) - monotonic, 0].max)
          end
        end
      end
      snapshots = []
      interval = [30.0, duration / 3.0].min
      loop do
        sleep([interval, started + duration - monotonic].min.clamp(0, interval))
        elapsed = monotonic - started
        current = cluster.workers.map { |worker| worker.fetch(:pid) }
        raise "workers changed during measurement" unless current.sort == worker_pids.sort

        rows = owned.map { |pid| memory(pid) }
        snapshots << { elapsed_seconds: elapsed, processes: rows, total_pss_bytes: rows.sum { |row| row.fetch(:pss_bytes) } }
        puts JSON.generate(event: "sampling", name:, elapsed_seconds: elapsed.round(1), requests:, errors:,
                           total_pss_bytes: snapshots.last.fetch(:total_pss_bytes))
        break if elapsed >= duration
      end
      threads.each(&:value)
      elapsed = monotonic - started
      rows = owned.map { |pid| memory(pid) }
      workers = rows.select { |row| worker_pids.include?(row[:pid]) }
      raise "RPC errors: #{errors}: #{error_examples.inspect}" unless errors.zero?
      raise "not all workers received requests: #{served.inspect}" unless served.keys.sort == worker_pids.sort

      row = { name:, workers: count, eager_preload:, warmup:, duration_seconds: elapsed, requests:, errors:, error_examples:,
              requests_by_pid: served, processes: rows, worker_memory: workers, total_pss_bytes: rows.sum { |entry| entry[:pss_bytes] },
              memory_snapshots: snapshots, final_three_total_pss_median_bytes: median(snapshots.last(3).map { |snapshot| snapshot.fetch(:total_pss_bytes) }) }
    ensure
      channels.each(&:close)
      cluster.stop(timeout: 5)
    end
    raise "unclean shutdown: #{cluster.logs}" unless cluster.wait.success?

    owned.each do |pid|
      Process.kill(0, pid)
      raise "owned process #{pid} survived shutdown"
    rescue Errno::ESRCH
      next
    end
    row[:owned_processes_reaped] = true
    results << row
    File.write(output_path, "#{JSON.pretty_generate(report)}\n")
    puts JSON.generate(event: "completed", name:, duration_seconds: elapsed, requests:, errors:, all_workers_loaded: true,
                       owned_processes_reaped: true, total_pss_bytes: row.fetch(:final_three_total_pss_median_bytes))
  end
end
single_pid = results.first.fetch(:worker_memory).first.fetch(:pid)
baseline_rss = median(results.first.fetch(:memory_snapshots).last(3).map do |snapshot|
  snapshot.fetch(:processes).find { |process| process.fetch(:pid) == single_pid }.fetch(:rss_bytes)
end)
results.each do |row|
  row[:max_worker_pss_to_single_rss] = row.fetch(:worker_memory).map { |worker| worker.fetch(:pss_bytes).fdiv(baseline_rss) }.max
end
increments = results.select { |row| row[:warmup] && row[:workers].positive? }.each_cons(2).map do |previous, current|
  bytes = current.fetch(:final_three_total_pss_median_bytes) - previous.fetch(:final_three_total_pss_median_bytes)
  { worker_count_from: previous.fetch(:workers), worker_count_to: current.fetch(:workers), additional_fleet_pss_bytes: bytes,
    additional_pss_to_single_rss: bytes.fdiv(baseline_rss) }
end
report.merge!(completed_at: Time.now.utc.iso8601, complete: true, baseline_single_rss_bytes: baseline_rss,
              measurement: "median of final three 30-second smaps_rollup snapshots; same preloaded master plus N workers, N=1..4",
              additional_workers: increments, gate_passed: increments.all? { |row| row.fetch(:additional_pss_to_single_rss) <= 0.4 })
File.write(output_path, "#{JSON.pretty_generate(report)}\n")
raise "additional preloaded worker PSS exceeded 40% of single process RSS" unless report.fetch(:gate_passed)

maximum = increments.map { |row| row.fetch(:additional_pss_to_single_rss) }.max
puts "Rails memory gate passed: maximum additional worker PSS #{(maximum * 100).round(2)}% <= 40%."
