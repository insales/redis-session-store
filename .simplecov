if ENV['COVERAGE']
  SimpleCov.start do
    enable_coverage :branch # available in ruby >= 2.5, already required by actionpack 6
    minimum_coverage branch: 100, line: 100
    add_filter '/spec/'
  end
end
