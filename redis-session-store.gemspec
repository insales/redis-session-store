Gem::Specification.new do |gem|
  gem.name = 'redis-session-store'
  gem.authors = ['Mathias Meyer']
  gem.email = ['meyer@paperplanes.de']
  gem.summary = 'A drop-in replacement for e.g. MemCacheStore to ' \
                'store Rails sessions (and Rails sessions only) in Redis.'
  gem.description = "#{gem.summary} For great glory!"
  gem.homepage = 'https://github.com/roidrage/redis-session-store'
  gem.license = 'MIT'

  gem.extra_rdoc_files = %w(LICENSE AUTHORS.md CONTRIBUTING.md)

  gem.files = `git ls-files -z`.split("\x0")
  gem.require_paths = %w(lib)
  gem.version = File.read('lib/redis-session-store.rb')
                    .match(/^  VERSION = '(.*)'/)[1]

  gem.add_dependency 'actionpack', '>= 6', '< 8.2'
  gem.add_dependency 'redis', '>= 4.2', '< 6'
end
