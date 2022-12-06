unless defined?(Rails)
  require 'logger'

  module Rails
    def self.logger
      @logger ||= Logger.new('/dev/null')
    end
  end
end
