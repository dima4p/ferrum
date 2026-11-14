# frozen_string_literal: true

describe Ferrum::Browser, "GC cleanup", :launch,
  if: Ferrum::Utils::Platform.mri? && !Ferrum::Utils::Platform.windows? do
  def start_browser_and_capture_resources
    browser = Ferrum::Browser.new
    process = browser.process
    client = browser.client
    web_socket = client.instance_variable_get(:@ws)
    subscriber = client.subscriber
    user_data_dir = process.instance_variable_get(:@user_data_dir)
    temp_dir = process.instance_variable_get(:@temp_dir)

    {
      pid: process.pid,
      user_data_dir: user_data_dir,
      temp_dir: temp_dir,
      chromium_temp_dirs: Dir.glob(File.join(temp_dir || Dir.tmpdir, "org.chromium.Chromium.*")),
      socket: web_socket.instance_variable_get(:@sock),
      reader: web_socket.instance_variable_get(:@thread),
      writer: web_socket.instance_variable_get(:@writer),
      subscriber_threads: %i[@regular_thread @priority_thread].map do |name|
        subscriber.instance_variable_get(name)
      end
    }
  end

  def wait_for_gc_cleanup
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 10
    GC.start
    until yield
      raise "GC cleanup did not finish" if
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

  def cleanup_resources(resources)
    pid = resources[:pid]
    begin
      ::Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end

    socket = resources[:socket]
    socket.close if socket && !socket.closed?
    [resources[:writer], *resources[:subscriber_threads]].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
    reader = resources[:reader]
    if reader&.alive?
      reader.kill
      reader.join
    end
    user_data_dir = resources[:user_data_dir]
    FileUtils.remove_entry(user_data_dir) if user_data_dir && Dir.exist?(user_data_dir)
  end

  it "terminates the Chromium process after browser GC" do
    resources = start_browser_and_capture_resources
    wait_for_gc_cleanup { !process_alive?(resources[:pid]) }
    expect(process_alive?(resources[:pid])).to be(false)
  ensure
    cleanup_resources(resources) if resources
  end

  it "terminates Chromium child processes after browser GC" do
    resources = start_browser_and_capture_resources
    wait_for_gc_cleanup { !process_group_alive?(resources[:pid]) }
    expect(process_group_alive?(resources[:pid])).to be(false)
  ensure
    cleanup_resources(resources) if resources
  end

  it "removes the Ferrum user data directory after browser GC" do
    resources = start_browser_and_capture_resources
    wait_for_gc_cleanup { !Dir.exist?(resources[:user_data_dir]) }
    expect(Dir.exist?(resources[:user_data_dir])).to be(false)
  ensure
    cleanup_resources(resources) if resources
  end

  it "removes Chromium's temporary directories after browser GC" do
    resources = start_browser_and_capture_resources
    chromium_temp_dirs = resources[:chromium_temp_dirs]
    expect(chromium_temp_dirs).not_to be_empty
    wait_for_gc_cleanup do
      chromium_temp_dirs.none? { |path| File.exist?(path) } &&
        !Dir.exist?(resources[:temp_dir])
    end
    expect(chromium_temp_dirs).to all(satisfy { |path| !File.exist?(path) })
    expect(Dir.exist?(resources[:temp_dir])).to be(false)
  ensure
    cleanup_resources(resources) if resources
  end

  it "closes the WebSocket and its reader and writer threads after browser GC" do
    resources = start_browser_and_capture_resources
    wait_for_gc_cleanup do
      resources[:socket].closed? &&
        !resources[:reader].alive? &&
        !resources[:writer].alive?
    end

    expect(resources[:socket]).to be_closed
    expect(resources[:reader]).not_to be_alive
    expect(resources[:writer]).not_to be_alive
  ensure
    cleanup_resources(resources) if resources
  end

  it "stops subscriber threads after browser GC" do
    resources = start_browser_and_capture_resources
    wait_for_gc_cleanup do
      resources[:subscriber_threads].none?(&:alive?)
    end

    expect(resources[:subscriber_threads]).to all(satisfy { |thread| !thread.alive? })
  ensure
    cleanup_resources(resources) if resources
  end
end
