# frozen_string_literal: true

require "tmpdir"

describe Ferrum::Browser, "cleanup lifecycle", :launch,
  if: Ferrum::Utils::Platform.mri? && Ferrum::Utils::Platform.platform_name == :linux do
  def start_browser_and_capture_resources
    chromium_temp_dirs_before = Dir.glob(File.join(Dir.tmpdir, "org.chromium.Chromium.*"))
    browser = Ferrum::Browser.new
    process = browser.process
    client = browser.client
    web_socket = client.instance_variable_get(:@ws)
    subscriber = client.subscriber
    user_data_dir = process.instance_variable_get(:@user_data_dir)

    # Support both Chromium's system temp directory and Ferrum's isolated temp directory.
    chromium_temp_dirs = (
      Dir.glob(File.join(Dir.tmpdir, "org.chromium.Chromium.*")) - chromium_temp_dirs_before
    )
    if user_data_dir
      chromium_temp_dirs.concat(Dir.glob(File.join(user_data_dir, "**", "org.chromium.Chromium.*")))
    end
    chromium_temp_dirs.uniq!

    {
      browser: browser,
      pid: process.pid,
      user_data_dir: user_data_dir,
      chromium_temp_dirs: chromium_temp_dirs,
      socket: web_socket.instance_variable_get(:@sock),
      websocket_reader: web_socket.instance_variable_get(:@thread),
      websocket_writer: web_socket.instance_variable_get(:@writer),
      client_reader: client.instance_variable_get(:@thread),
      subscriber_threads: %i[@regular_thread @priority_thread].map do |name|
        subscriber.instance_variable_get(name)
      end,
      outgoing: web_socket.instance_variable_get(:@outgoing),
      subscriber_queues: %i[@regular @priority].map do |name|
        subscriber.instance_variable_get(name)
      end
    }
  end

  def process_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def process_group_alive?(pid)
    ::Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_for_cleanup(timeout: 15)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "Browser cleanup did not finish within #{timeout} seconds" if
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline

      GC.start
      sleep 0.05
    end
  end

  # Read /proc while the browser is still alive. Capture the process tree,
  # members of Chromium's original process group, and processes carrying this
  # browser's user-data path. The latter two also catch reparented processes.
  def process_snapshot
    Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
      stat = File.read(path)
      fields = stat[(stat.rindex(") ") + 2)..].split
      pid = File.basename(File.dirname(path)).to_i
      cmdline = File.read("/proc/#{pid}/cmdline").tr("\0", " ").strip
      {
        pid: pid,
        state: fields[0],
        ppid: fields[1].to_i,
        pgid: fields[2].to_i,
        starttime: fields[19],
        command: cmdline
      }
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end
  end

  def process_tree_snapshot(root_pid, user_data_dir = nil)
    table = process_snapshot
    by_ppid = table.group_by { |process| process[:ppid] }
    descendants = []
    pending = [root_pid]
    seen = {}

    until pending.empty?
      parent_pid = pending.shift
      next if seen[parent_pid]

      seen[parent_pid] = true
      children = by_ppid.fetch(parent_pid, [])
      descendants.concat(children)
      pending.concat(children.map { |process| process[:pid] })
    end

    root = table.find { |process| process[:pid] == root_pid }
    related = table.select do |process|
      process[:pgid] == root_pid ||
        (user_data_dir && process[:command].include?(user_data_dir))
    end
    [root, *descendants, *related].compact.uniq { |process| process[:pid] }
  end

  # Match PID and start time to avoid mistaking a reused PID for the original
  # Chromium process. Zombies are reported separately but are no longer running.
  def surviving_processes(captured)
    captured.filter_map do |process|
      path = "/proc/#{process[:pid]}/stat"
      stat = File.read(path)
      fields = stat[(stat.rindex(") ") + 2)..].split
      next unless fields[19] == process[:starttime]
      next if fields[0] == "Z"

      cmdline = File.read("/proc/#{process[:pid]}/cmdline").tr("\0", " ").strip
      process.merge(state: fields[0], current_ppid: fields[1].to_i, command: cmdline)
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end
  end

  def process_starttime(pid)
    stat = File.read("/proc/#{pid}/stat")
    stat[(stat.rindex(") ") + 2)..].split[19]
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def client_threads(resources)
    [
      resources[:websocket_reader],
      resources[:websocket_writer],
      resources[:client_reader],
      *resources[:subscriber_threads]
    ].compact
  end

  def client_resources_closed?(resources)
    resources[:socket].closed? && client_threads(resources).none?(&:alive?)
  end

  def cleanup_resources(resources)
    return unless resources

    # Kill any captured descendants individually as a safety net. They may
    # have escaped the browser's original process group after the snapshot.
    (resources[:captured_processes] || []).each do |process|
      next unless process_starttime(process[:pid]) == process[:starttime]

      begin
        ::Process.kill("KILL", process[:pid])
      rescue Errno::ESRCH
        nil
      end
    end

    pid = resources[:pid]
    begin
      ::Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end

    socket = resources[:socket]
    socket.close if socket && !socket.closed?
    client_threads(resources).each do |thread|
      thread.kill if thread.alive?
      thread.join
    end

    (resources[:chromium_temp_dirs] || []).each do |path|
      FileUtils.remove_entry(path) if File.exist?(path)
    end
    user_data_dir = resources[:user_data_dir]
    FileUtils.remove_entry(user_data_dir) if user_data_dir && Dir.exist?(user_data_dir)
  end

  describe "Browser#quit" do
    it "terminates Chromium and all of its child processes" do
      resources = start_browser_and_capture_resources
      captured = process_tree_snapshot(resources[:pid], resources[:user_data_dir])
      resources[:captured_processes] = captured
      resources[:browser].quit

      wait_for_cleanup { surviving_processes(captured).empty? }
      remaining = surviving_processes(captured)
      expect(remaining).to be_empty,
        "Chromium processes survived Browser#quit: #{remaining.inspect}"
    ensure
      cleanup_resources(resources)
    end

    it "removes the Ferrum user data directory" do
      resources = start_browser_and_capture_resources
      resources[:browser].quit

      wait_for_cleanup { !Dir.exist?(resources[:user_data_dir]) }
      expect(Dir.exist?(resources[:user_data_dir])).to be(false)
    ensure
      cleanup_resources(resources)
    end

    it "closes the WebSocket and stops client and subscriber threads" do
      resources = start_browser_and_capture_resources
      resources[:browser].quit
      wait_for_cleanup { client_resources_closed?(resources) }
      expect(resources[:socket]).to be_closed
      expect(client_threads(resources)).to all(satisfy { |thread| !thread.alive? })
    ensure
      cleanup_resources(resources)
    end

    it "removes Chromium temporary directories" do
      resources = start_browser_and_capture_resources
      expect(resources[:chromium_temp_dirs]).not_to be_empty
      resources[:browser].quit

      wait_for_cleanup do
        resources[:chromium_temp_dirs].none? { |path| File.exist?(path) }
      end
      expect(resources[:chromium_temp_dirs]).to all(satisfy { |path| !File.exist?(path) })
    ensure
      cleanup_resources(resources)
    end

    it "reliably terminates Chromium and removes its user data directory across repeated browser lifecycles" do
      iterations = Integer(ENV.fetch("FERRUM_CLEANUP_STRESS_ITERATIONS", "100"))
      failures = []

      iterations.times do |index|
        resources = start_browser_and_capture_resources
        pid = resources[:pid]
        user_data_dir = resources[:user_data_dir]
        captured = process_tree_snapshot(pid, user_data_dir)
        resources[:captured_processes] = captured

        resources[:browser].quit

        # Inspect immediately: waiting here would hide the race between the
        # process-group SIGKILL and removal of the user-data directory.
        surviving = surviving_processes(captured)
        running_group_members = process_snapshot.select do |process|
          process[:pgid] == pid && process[:state] != "Z"
        end
        user_data_dir_exists = Dir.exist?(user_data_dir)

        unless surviving.empty? && running_group_members.empty? && !user_data_dir_exists
          failures << {
            iteration: index + 1,
            browser_pid: pid,
            surviving_processes: surviving,
            running_group_members: running_group_members,
            user_data_dir_exists: user_data_dir_exists
          }
        end
      ensure
        # Keep the observations above, then clean up only to avoid contaminating
        # subsequent examples. Never use this cleanup to determine pass/fail.
        cleanup_resources(resources)
      end

      expect(failures).to be_empty,
        "Browser#quit left resources behind during stress run: #{failures.inspect}"
    end
  end

  describe "process-group cleanup after the leader was reaped" do
    it "kills remaining Chromium children when Process.wait raises ECHILD" do
      reader, writer = IO.pipe
      script = <<~'RUBY'
        reader = IO.for_fd(ARGV[0].to_i)
        writer = IO.for_fd(ARGV[1].to_i)
        Signal.trap("TERM") { exit! }
        child = fork do
          reader.close
          Signal.trap("TERM", "IGNORE")
          writer.write("#{Process.pid}\n")
          writer.flush
          writer.close
          sleep
        end
        writer.close
        sleep
      RUBY
      reader.close_on_exec = false
      writer.close_on_exec = false
      pid = ::Process.spawn(RbConfig.ruby, "-e", script, reader.fileno.to_s, writer.fileno.to_s,
        pgroup: true, close_others: false, in: File::NULL, out: File::NULL, err: File::NULL)
      writer.close
      child_pid = Integer(reader.gets)
      reader.close

      ::Process.kill("TERM", pid)
      ::Process.wait(pid)
      expect(process_alive?(child_pid)).to be(true)

      Ferrum::Browser::Process::Killer.kill(pid)

      wait_for_cleanup { !process_alive?(child_pid) }
      expect(process_group_alive?(pid)).to be(false)
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      begin
        ::Process.kill("KILL", -pid) if pid
      rescue Errno::ESRCH
        nil
      end
      begin
        ::Process.wait(pid) if pid
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
  end

  describe "Browser GC" do
    it "terminates the Chromium process after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      wait_for_cleanup { !process_alive?(resources[:pid]) }
      expect(process_alive?(resources[:pid])).to be(false)
    ensure
      cleanup_resources(resources)
    end

    it "terminates Chromium child processes after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      wait_for_cleanup { !process_group_alive?(resources[:pid]) }
      expect(process_group_alive?(resources[:pid])).to be(false)
    ensure
      cleanup_resources(resources)
    end

    it "removes the Ferrum user data directory after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      wait_for_cleanup { !Dir.exist?(resources[:user_data_dir]) }
      expect(Dir.exist?(resources[:user_data_dir])).to be(false)
    ensure
      cleanup_resources(resources)
    end

    it "does not leave Chromium processes behind across repeated browser GC cycles" do
      iterations = Integer(ENV.fetch("FERRUM_CLEANUP_STRESS_ITERATIONS", "55"))
      leftovers = []

      iterations.times do |index|
        resources = start_browser_and_capture_resources
        captured = process_tree_snapshot(resources[:pid])
        resources[:captured_processes] = captured
        resources.delete(:browser)

        wait_for_cleanup { surviving_processes(captured).empty? }
        remaining = surviving_processes(captured)
        leftovers << { iteration: index + 1, browser_pid: resources[:pid], processes: remaining } unless remaining.empty?
      ensure
        cleanup_resources(resources)
      end

      expect(leftovers).to be_empty,
        "Chromium processes survived browser GC: #{leftovers.inspect}"
    end

    it "removes Chromium temporary directories after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      expect(resources[:chromium_temp_dirs]).not_to be_empty

      wait_for_cleanup do
        resources[:chromium_temp_dirs].none? { |path| File.exist?(path) }
      end
      expect(resources[:chromium_temp_dirs]).to all(satisfy { |path| !File.exist?(path) })
    ensure
      cleanup_resources(resources)
    end

    it "closes the WebSocket socket after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)

      wait_for_cleanup { resources[:socket].closed? }
      expect(resources[:socket]).to be_closed
    ensure
      cleanup_resources(resources)
    end

    it "stops the WebSocket writer thread after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      thread = resources[:websocket_writer]

      wait_for_cleanup { !thread.alive? }
      expect(thread).not_to be_alive
    ensure
      cleanup_resources(resources)
    end

    it "stops the regular subscriber thread after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      thread = resources[:subscriber_threads][0]

      wait_for_cleanup { !thread.alive? }
      expect(thread).not_to be_alive
    ensure
      cleanup_resources(resources)
    end

    it "stops the priority subscriber thread after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      thread = resources[:subscriber_threads][1]

      wait_for_cleanup { !thread.alive? }
      expect(thread).not_to be_alive
    ensure
      cleanup_resources(resources)
    end

    it "closes the WebSocket outgoing queue after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      outgoing = resources[:outgoing]

      wait_for_cleanup { outgoing.closed? }
      expect(outgoing).to be_closed
    ensure
      cleanup_resources(resources)
    end

    it "stops both subscriber threads after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      threads = resources[:subscriber_threads]

      wait_for_cleanup { threads.none?(&:alive?) }
      expect(threads).to all(satisfy { |thread| !thread.alive? })
    ensure
      cleanup_resources(resources)
    end

    it "stops the WebSocket writer and closes its outgoing queue after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)
      writer = resources[:websocket_writer]
      outgoing = resources[:outgoing]

      wait_for_cleanup { !writer.alive? && outgoing.closed? }
      expect(writer).not_to be_alive
      expect(outgoing).to be_closed
    ensure
      cleanup_resources(resources)
    end

    it "closes the WebSocket and stops its reader, writer and client threads after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)

      wait_for_cleanup { client_resources_closed?(resources) }
      expect(resources[:socket]).to be_closed
      expect(client_threads(resources)).to all(satisfy { |thread| !thread.alive? })
    ensure
      cleanup_resources(resources)
    end

  end
end
