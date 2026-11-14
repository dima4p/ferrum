# frozen_string_literal: true

require "tmpdir"

describe Ferrum::Browser, "cleanup lifecycle", :launch,
  if: Ferrum::Utils::Platform.mri? && !Ferrum::Utils::Platform.windows? do
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

    resources = {
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
      end
    }

    resources
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
    it "terminates Chromium and its child processes" do
      resources = start_browser_and_capture_resources
      resources[:browser].quit

      expect(process_alive?(resources[:pid])).to be(false)
      expect(process_group_alive?(resources[:pid])).to be(false)
    ensure
      cleanup_resources(resources)
    end

    it "removes the Ferrum user data directory" do
      resources = start_browser_and_capture_resources
      resources[:browser].quit

      expect(Dir.exist?(resources[:user_data_dir])).to be(false)
    ensure
      cleanup_resources(resources)
    end

    it "removes Chromium temporary directories" do
      resources = start_browser_and_capture_resources
      expect(resources[:chromium_temp_dirs]).not_to be_empty
      resources[:browser].quit

      expect(resources[:chromium_temp_dirs]).to all(satisfy { |path| !File.exist?(path) })
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

    it "closes the WebSocket and stops its reader, writer and client threads after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)

      wait_for_cleanup { client_resources_closed?(resources) }
      expect(resources[:socket]).to be_closed
      expect(client_threads(resources)).to all(satisfy { |thread| !thread.alive? })
    ensure
      cleanup_resources(resources)
    end

    it "stops subscriber threads after browser GC" do
      resources = start_browser_and_capture_resources
      resources.delete(:browser)

      wait_for_cleanup do
        resources[:subscriber_threads].none?(&:alive?)
      end
      expect(resources[:subscriber_threads]).to all(satisfy { |thread| !thread.alive? })
    ensure
      cleanup_resources(resources)
    end
  end
end
