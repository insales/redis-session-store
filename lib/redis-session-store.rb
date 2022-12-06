require 'redis'
require 'active_support/core_ext/hash/indifferent_access'
require 'action_dispatch'
require 'action_dispatch/middleware/session/abstract_store'

# Redis session storage for Rails, and for Rails only. Derived from
# the MemCacheStore code, simply dropping in Redis instead.
class RedisSessionStore < ActionDispatch::Session::AbstractSecureStore
  VERSION = '0.11.5'.freeze
  # :nocov:
  ENV_SESSION_OPTIONS_KEY = Rack::RACK_SESSION_OPTIONS unless defined?(ENV_SESSION_OPTIONS_KEY)
  # :nocov:

  # ==== Options
  # * +:key+ - Same as with the other cookie stores, key name
  # * +:redis+ - A hash with redis-specific options
  #   * +:url+ - Redis url, default is redis://localhost:6379/0
  #   * +:key_prefix+ - Prefix for keys used in Redis, e.g. +myapp:+
  #   * +:expire_after+ - A number in seconds for session timeout
  #   * +:client+ - Connect to Redis with given object rather than create one
  # * +:on_redis_down:+ - Called with err, rack request, and SID on Errno::ECONNREFUSED
  # * +:on_session_load_error:+ - Called with err and SID on Marshal.load fail
  # * +:serializer:+ - Serializer to use on session data, default is :marshal.
  #
  # ==== Examples
  #
  #     Rails.application.config.session_store :redis_session_store,
  #       key: 'your_session_key',
  #       redis: {
  #         expire_after: 120.minutes,
  #         key_prefix: 'myapp:session:',
  #         url: 'redis://localhost:6379/0'
  #       },
  #       on_redis_down: ->(*a) { logger.error("Redis down! #{a.inspect}") },
  #       serializer: :hybrid # migrate from Marshal to JSON
  #
  def initialize(app, options = {})
    super

    @default_options[:namespace] = 'rack:session'
    @default_options.merge!(options[:redis] || {})
    init_options = options[:redis]&.reject { |k, _v| %i[expire_after key_prefix].include?(k) } || {}
    @redis = init_options[:client] || Redis.new(init_options)
    @on_redis_down = options[:on_redis_down]
    @serializer = determine_serializer(options[:serializer])
    @on_session_load_error = options[:on_session_load_error]
    verify_handlers!
  end

  attr_accessor :on_redis_down, :on_session_load_error

  private

  attr_reader :redis, :key, :default_options, :serializer

  # overrides method defined in rack to actually verify session existence
  # Prevents needless new sessions from being created in scenario where
  # user HAS session id, but it already expired, or is invalid for some
  # other reason, and session was accessed only for reading.
  def session_exists?(request)
    value = current_session_id(request)

    !!(
      value && !value.empty? &&
      redis.exists?(prefixed(value))
    )
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, request, value) if on_redis_down

    true
  end

  def verify_handlers!
    %w(on_redis_down on_session_load_error).each do |h|
      next unless (handler = public_send(h)) && !handler.respond_to?(:call)

      raise ArgumentError, "#{h} handler is not callable"
    end
  end

  def prefixed(sid)
    "#{default_options[:key_prefix]}#{sid}"
  end

  def session_default_values
    [generate_sid, {}.with_indifferent_access]
  end

  def find_session(request, sid)
    sid && (session = load_session_from_redis(sid)) ? [sid, session] : session_default_values
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, request, sid) if on_redis_down
    session_default_values
  end

  def load_session_from_redis(sid)
    data = redis.get(prefixed(sid))
    begin
      data ? decode(data) : nil
    rescue StandardError => e
      destroy_session_from_sid(sid, drop: true)
      on_session_load_error.call(e, sid) if on_session_load_error
      nil
    end
  end

  def decode(data)
    session = serializer.load(data)
    session.with_indifferent_access
  end

  def write_session(request, sid, session_data, options = nil)
    expiry = get_expiry(request, options)
    if expiry
      redis.setex(prefixed(sid), expiry, encode(session_data))
    else
      redis.set(prefixed(sid), encode(session_data))
    end
    sid
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, request, sid) if on_redis_down
    false
  end

  def get_expiry(request, options)
    session_storage_options = options || request.env.fetch(ENV_SESSION_OPTIONS_KEY, {})
    session_storage_options[:ttl] || session_storage_options[:expire_after]
  end

  def encode(session_data)
    serializer.dump(session_data)
  end

  def delete_session(request, sid, options)
    destroy_session_from_sid(sid, (options || {}).to_hash.merge(request: request))
  end

  def destroy(request)
    if request.env['rack.request.cookie_hash'] &&
       (sid = request.env['rack.request.cookie_hash'][key])
      destroy_session_from_sid(sid, drop: true, request: request)
    end
    false
  end

  def destroy_session_from_sid(sid, options = {})
    redis.del(prefixed(sid))
    (options || {})[:drop] ? nil : generate_sid
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down.call(e, options[:request] || {}, sid) if on_redis_down
  end

  def determine_serializer(serializer)
    serializer ||= :marshal
    case serializer
    when :marshal then Marshal
    when :json    then JsonSerializer
    when :hybrid  then HybridSerializer
    else serializer
    end
  end

  # Uses built-in JSON library to encode/decode session
  class JsonSerializer
    def self.load(value)
      JSON.parse(value, quirks_mode: true)
    end

    def self.dump(value)
      JSON.generate(value, quirks_mode: true)
    end
  end

  # Transparently migrates existing session values from Marshal to JSON
  class HybridSerializer < JsonSerializer
    MARSHAL_SIGNATURE = "\x04\x08".freeze

    def self.load(value)
      if needs_migration?(value)
        Marshal.load(value)
      else
        super
      end
    end

    def self.needs_migration?(value)
      value.start_with?(MARSHAL_SIGNATURE)
    end
  end
end
