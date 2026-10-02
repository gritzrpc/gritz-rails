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

def single_rss_bytes(result)
  pid = result.fetch(:worker_memory).first.fetch(:pid)
  median(result.fetch(:memory_snapshots).last(3).map do |snapshot|
    snapshot.fetch(:processes).find { |process| process.fetch(:pid) == pid }.fetch(:rss_bytes)
  end)
end

def additional_workers(results, baseline_rss)
  results.select { |row| row[:warmup] && row[:workers].positive? }.each_cons(2).map do |previous, current|
    bytes = current.fetch(:final_three_total_pss_median_bytes) - previous.fetch(:final_three_total_pss_median_bytes)
    { worker_count_from: previous.fetch(:workers), worker_count_to: current.fetch(:workers), additional_fleet_pss_bytes: bytes,
      additional_pss_to_single_rss: bytes.fdiv(baseline_rss) }
  end
end

def gc_counters(logs)
  logs.lines.filter_map do |line|
    JSON.parse(line.delete_prefix("GRITZ_MEMORY_GC "), symbolize_names: true) if line.start_with?("GRITZ_MEMORY_GC ")
  end
end

case_set = ENV.fetch("CASE_SET", "full")
abort "CASE_SET must be full or fixed_gate" unless %w[full fixed_gate].include?(case_set)
cases = [["single", 0, true, false], ["no_eager_preload", 4, false, false],
         ["preload", 4, true, false], *1.upto(4).map { |count| ["preload_warmup_#{count}", count, true, true] }]
cases = cases.select { |name, _count, _eager, warmup| name == "single" || warmup } if case_set == "fixed_gate"
results = []
$stdout.sync = true
core_root = Gem.loaded_specs.fetch("gritz-core").full_gem_path
source_paths = [__FILE__, *Dir[File.join(sample, "{app,config,db,lib}", "**", "*.{rb,proto,yml}")],
                *Dir[File.expand_path("../lib/gritz/**/*.rb", __dir__)],
                *Dir[File.join(core_root, "lib/**/*.rb")]].map { |path| File.expand_path(path) }.sort
workspace = File.expand_path("../..", __dir__)
source_hashes = source_paths.to_h { |path| [path.delete_prefix("#{workspace}/"), Digest::SHA256.file(path).hexdigest] }
report = { started_at: Time.now.utc.iso8601, ruby: RUBY_DESCRIPTION, rails: Gem.loaded_specs.fetch("railties").version.to_s,
           active_record: Gem.loaded_specs.fetch("activerecord").version.to_s, sqlite3: Gem.loaded_specs.fetch("sqlite3").version.to_s,
           grpc: Gem.loaded_specs.fetch("grpc").version.to_s, kernel: File.read("/proc/version").strip,
           duration_per_case: duration, sequential: true, case_set:, cpu_count: Etc.nprocessors,
           core_source_root: core_root, core_source_commit: ENV.fetch("RAILS_MEMORY_CORE_COMMIT", nil),
           gc_policy: case_set == "full" ? "ordinary GC control" : "sample before_fork opt-in",
           gc_probe: case_set == "fixed_gate" ? "four scalar GC values at first before_fork, master exit, worker boot/shutdown" : nil,
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
    if case_set == "full"
      config_source += "before_fork { GC.config(rgengc_allow_full_mark: true) if GC.respond_to?(:config) }\n"
    end
    if case_set == "fixed_gate"
      config_source += <<~RUBY
        gc_probe = lambda do |stage|
          STDERR.puts("GRITZ_MEMORY_GC " + JSON.generate(stage:, pid: Process.pid,
            major_gc_count: GC.stat(:major_gc_count), minor_gc_count: GC.stat(:minor_gc_count),
            need_major_by: GC.latest_gc_info(:need_major_by),
            allow_full_mark: GC.respond_to?(:config) ? GC.config[:rgengc_allow_full_mark] : nil))
        end
        before_fork do |index|
          if index.zero?
            master_pid = Process.pid
            gc_probe.call("before_fork")
            at_exit { gc_probe.call("master_exit") if Process.pid == master_pid }
          end
        end
        on_worker_boot { |_index| gc_probe.call("worker_boot") }
        on_worker_shutdown { |_index| gc_probe.call("worker_shutdown") }
      RUBY
    end
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
      startup_gc = gc_counters(cluster.logs) if case_set == "fixed_gate"
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
    if case_set == "fixed_gate"
      row[:gc_counters] = (startup_gc + gc_counters(cluster.logs)).uniq
      %w[worker_boot worker_shutdown].each do |stage|
        pids = row.fetch(:gc_counters).select { |entry| entry.fetch(:stage) == stage }.map { |entry| entry.fetch(:pid) }
        raise "missing #{stage} GC probe: #{pids.inspect}" unless pids.sort == worker_pids.sort
      end
      if count.positive? && row.fetch(:gc_counters).count { |entry| %w[before_fork master_exit].include?(entry.fetch(:stage)) } != 2
        raise "missing master GC probe"
      end
    end
    results << row
    baseline_rss = single_rss_bytes(results.first)
    row[:max_worker_pss_to_single_rss] = row.fetch(:worker_memory).map { |worker| worker.fetch(:pss_bytes).fdiv(baseline_rss) }.max
    increments = additional_workers(results, baseline_rss)
    report.merge!(baseline_single_rss_bytes: baseline_rss, additional_workers: increments)
    failed = case_set == "fixed_gate" && increments.any? { |increment| increment.fetch(:additional_pss_to_single_rss) > 0.4 }
    report.merge!(gate_passed: false, stopped_after: name, stop_reason: "additional worker PSS exceeded 40%") if failed
    File.write(output_path, "#{JSON.pretty_generate(report)}\n")
    puts JSON.generate(event: "completed", name:, duration_seconds: elapsed, requests:, errors:, all_workers_loaded: true,
                       owned_processes_reaped: true, total_pss_bytes: row.fetch(:final_three_total_pss_median_bytes))
    abort "additional preloaded worker PSS exceeded 40%; remaining cases were not measured" if failed
  end
end
baseline_rss = single_rss_bytes(results.first)
increments = additional_workers(results, baseline_rss)
report.merge!(completed_at: Time.now.utc.iso8601, complete: true, baseline_single_rss_bytes: baseline_rss,
              measurement: "median of final three 30-second smaps_rollup snapshots; same preloaded master plus N workers, N=1..4",
              additional_workers: increments, gate_passed: increments.all? { |row| row.fetch(:additional_pss_to_single_rss) <= 0.4 })
File.write(output_path, "#{JSON.pretty_generate(report)}\n")
raise "additional preloaded worker PSS exceeded 40% of single process RSS" unless report.fetch(:gate_passed)

maximum = increments.map { |row| row.fetch(:additional_pss_to_single_rss) }.max
puts "Rails memory gate passed: maximum additional worker PSS #{(maximum * 100).round(2)}% <= 40%."
