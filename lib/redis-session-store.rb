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
  # * +:keep_sid:+ - Keep sid for sessions that are expired in redis.
  # * +:skip_exists:+ - Make session existance check not call redis, saves a couple of ms.
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
    @serializer = determine_serializer(options[:serializer])
    %i[on_redis_down on_session_load_error keep_sid skip_exists].each do |option|
      instance_variable_set(:"@#{option}", options[option])
    end
    verify_handlers!
  end

  attr_accessor :on_redis_down, :on_session_load_error

  private

  attr_reader :key, :default_options, :serializer, :keep_sid, :skip_exists

  def redis(_request)
    @redis
  end

  # overrides method defined in rack to actually verify session existence
  # Prevents needless new sessions from being created in scenario where
  # user HAS session id, but it already expired, or is invalid for some
  # other reason, and session was accessed only for reading.
  def session_exists?(request)
    value = current_session_id(request)

    !!(
      value && !value.empty? &&
      ((skip_exists && !value.to_s.empty?) || redis(request).exists?(prefixed(value)))
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

  def generate_sid(_request)
    super()
  end

  def prefixed(sid)
    "#{default_options[:key_prefix]}#{sid}"
  end

  def session_default_value
    {}.with_indifferent_access
  end

  def find_session(request, sid)
    if sid
      session = begin
        load_session_from_redis(request, sid) || (keep_sid && session_default_value)
      rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
        on_redis_down&.call(e, request, sid)
        nil
      end
      return [sid, session] if session
    end

    [generate_sid(request), session_default_value]
  end

  def read_from_redis(_request, redis_overridable, key)
    redis_overridable.get(key)
  end

  def load_session_from_redis(request, sid)
    data = read_from_redis(request, redis(request), prefixed(sid))
    begin
      data ? decode(data) : nil
    rescue StandardError => e
      delete_session_in_redis(request, sid)
      on_session_load_error&.call(e, sid)
      nil
    end
  end

  def decode(data)
    session = serializer.load(data)
    session.with_indifferent_access
  end

  def write_session(request, sid, session_data, options = nil) # rubocop:disable Metrics/MethodLength
    if keep_sid && session_data.empty?
      delete_session_in_redis(request, sid)
    elsif (expiry = get_expiry(request, options))
      redis(request).setex(prefixed(sid), expiry, encode(session_data))
    else
      redis(request).set(prefixed(sid), encode(session_data))
    end
    sid
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down&.call(e, request, sid)
    false
  end

  # inject sid to make rack not call generate_sid, it is called from delete_session if needed
  def commit_session(request, res)
    session = request.get_header(Rack::RACK_SESSION)
    if !session.id && session.options.yield_self { |opt| opt[:drop] || opt[:renew] }
      tmp_sid = generate_sid(request)
      session.instance_variable_set(:@id, tmp_sid) # for plain rack
      session.options[:id] = tmp_sid # for actiondispatch
      raise 'cannot inject session id, Rack will fail on generate_sid' unless session.id
    end
    super
  end

  def get_expiry(request, options)
    session_storage_options = options || request.env.fetch(ENV_SESSION_OPTIONS_KEY, {})
    session_storage_options[:ttl] || session_storage_options[:expire_after]
  end

  def encode(session_data)
    serializer.dump(session_data)
  end

  def delete_session(request, sid, options)
    delete_session_in_redis(request, sid)
    return nil if options&.[](:drop)

    generate_sid(request)
  end

  def destroy(request)
    if (sid = request.env['rack.request.cookie_hash']&.[](key))
      delete_session_in_redis(request, sid)
    end
    false
  end

  def delete_session_in_redis(request, sid)
    redis(request).del(prefixed(sid))
  rescue Errno::ECONNREFUSED, Redis::CannotConnectError => e
    on_redis_down&.call(e, request, sid)
  end
end

# Serializers
class RedisSessionStore < ActionDispatch::Session::AbstractSecureStore
  def determine_serializer(serializer)
    serializer ||= :marshal
    case serializer
    when :marshal then Marshal
    when :json    then JsonSerializer
    when :hybrid  then HybridSerializer
    when :prehybrid then PreHybridSerializer
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

  # When hybrid is deployed, some processes can take more time to restart
  # and get json sessions from newly started hybrid ones, destroing these sessions and erroring
  # Use this prior to hybrid to prevent this.
  class PreHybridSerializer < HybridSerializer
    def self.dump(value)
      Marshal.dump(value)
    end
  end
end
