# frozen_string_literal: true

describe Ferrum::Browser, "GC cleanup", if: Ferrum::Utils::Platform.mri? && !Ferrum::Utils::Platform.windows? do
  it "reproduces the WebSocket and subscriber thread leak after browser GC" do
    browser = described_class.new
    process = browser.process
    client = browser.client
    web_socket = client.instance_variable_get(:@ws)
    socket = web_socket.instance_variable_get(:@sock)
    reader = web_socket.instance_variable_get(:@thread)
    writer = web_socket.instance_variable_get(:@writer)
    subscriber = client.subscriber
    subscriber_threads = %i[@regular_thread @priority_thread].map do |name|
      subscriber.instance_variable_get(name)
    end
    user_data_dir = process.instance_variable_get(:@user_data_dir)
    pid = process.pid

    # Keep references to the resources under test, but release Browser,
    # Process, and Client so the Process finalizer can run.
    browser = process = client = web_socket = subscriber = nil

    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 10
    GC.start
    until !Dir.exist?(user_data_dir) && !reader.alive?
      raise "Browser process finalizer did not finish" if
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline

      GC.start
      sleep 0.05
    end

    expect(socket).not_to be_closed
    expect(writer).to be_alive
    expect(subscriber_threads).to all(be_alive)
  ensure
    begin
      browser&.quit
    rescue StandardError
      nil
    end

    begin
      ::Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end

    socket&.close unless socket&.closed?
    [writer, *subscriber_threads].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
    FileUtils.remove_entry(user_data_dir) if user_data_dir && Dir.exist?(user_data_dir)
  end
end
