# frozen_string_literal: true

require "stringio"
require "logger"

describe Ferrum::Browser do
  describe ".new" do
    it "logs requests and responses with native Logger" do
      custom_logger = Class.new do
        def initialize(logger)
          @logger = logger
        end

        def puts(*args)
          @logger << args
        end
      end
      file_path = "test.log"
      logger = custom_logger.new(Logger.new(file_path))
      browser = Ferrum::Browser.new(logger: logger)
      browser.body
      file_log = File.read(file_path)
      expect(file_log).to include("document.documentElement?.outerHTML")
      expect(file_log).to include("<html><head></head><body></body></html>")
    ensure
      FileUtils.rm_f(file_path)
      browser.quit
    end

    it "logs requests and responses" do
      logger = StringIO.new
      browser = Ferrum::Browser.new(logger: logger)

      browser.body

      expect(logger.string).to include("document.documentElement?.outerHTML")
      expect(logger.string).to include("<html><head></head><body></body></html>")
    ensure
      browser.quit
    end

    it "passes browser_options to the command line" do
      browser = Ferrum::Browser.new(browser_options: { "blink-settings" => "imagesEnabled=false" })

      arguments = browser.command("Browser.getBrowserCommandLine")["arguments"]

      expect(arguments).to include("--blink-settings=imagesEnabled=false")
    ensure
      browser.quit
    end
  end

  describe "#restart" do
    it "restarts a browser whose previous start died after the client was built" do
      browser = Ferrum::Browser.new

      error = StandardError.new
      allow(Ferrum::Contexts).to receive(:new).and_raise(error)
      expect { browser.restart }.to raise_error(error)

      allow(Ferrum::Contexts).to receive(:new).and_call_original

      expect { browser.restart }.not_to raise_error
      expect(browser.contexts).not_to be_nil
    ensure
      browser&.quit
    end
  end
end

describe Ferrum::Browser do
  describe "#quit" do
    it "stops the process when closing context connections raises" do
      error = StandardError.new("context cleanup failed")
      contexts = double(close_connections: nil)
      client = double(close: nil)
      process = double(stop: nil)
      browser = described_class.allocate
      browser.instance_variable_set(:@contexts, contexts)
      browser.instance_variable_set(:@client, client)
      browser.instance_variable_set(:@process, process)
      allow(contexts).to receive(:close_connections).and_raise(error)

      expect { browser.quit }.to raise_error(error)

      expect(client).to have_received(:close)
      expect(process).to have_received(:stop).with(wait: true)
      expect(browser.client).to be_nil
      expect(browser.process).to be_nil
      expect(browser.contexts).to be_nil
    end

    it "stops the process when closing the client raises" do
      error = StandardError.new("client cleanup failed")
      contexts = double(close_connections: nil)
      client = double
      process = double(stop: nil)
      browser = described_class.allocate
      browser.instance_variable_set(:@contexts, contexts)
      browser.instance_variable_set(:@client, client)
      browser.instance_variable_set(:@process, process)
      allow(client).to receive(:close).and_raise(error)

      expect { browser.quit }.to raise_error(error)

      expect(process).to have_received(:stop).with(wait: true)
    end
  end
end
