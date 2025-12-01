unless defined?(Rails)
  require 'logger'

  module Rails
    def self.logger
      @logger ||= Logger.new(File::NULL)
    end
  end
end
