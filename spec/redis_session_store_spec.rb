require 'json'

describe RedisSessionStore do
  subject(:store) { described_class.new(nil, options) }

  let :random_string do
    "#{rand}#{rand}#{rand}"
  end
  let :default_options do
    store.instance_variable_get(:@default_options)
  end

  let :options do
    {}
  end

  it 'assigns a :namespace to @default_options' do
    expect(default_options[:namespace]).to eq('rack:session')
  end

  describe 'when initializing with the redis sub-hash options' do
    let :options do
      {
        key: random_string,
        secret: random_string,
        redis: {
          host: 'hosty.local',
          port: 16_379,
          db: 2,
          key_prefix: 'myapp:session:',
          expire_after: 60 * 120
        }
      }
    end

    it 'creates a redis instance' do
      expect(store.send(:redis, double('request'))).not_to be_nil
    end

    it 'assigns the :host option to @default_options' do
      expect(default_options[:host]).to eq('hosty.local')
    end

    it 'assigns the :port option to @default_options' do
      expect(default_options[:port]).to eq(16_379)
    end

    it 'assigns the :db option to @default_options' do
      expect(default_options[:db]).to eq(2)
    end

    it 'assigns the :key_prefix option to @default_options' do
      expect(default_options[:key_prefix]).to eq('myapp:session:')
    end

    it 'assigns the :expire_after option to @default_options' do
      expect(default_options[:expire_after]).to eq(60 * 120)
    end
  end

  describe 'when configured with both :ttl and :expire_after' do
    let(:ttl_seconds) { 60 * 120 }
    let :options do
      {
        key: random_string,
        secret: random_string,
        redis: {
          host: 'hosty.local',
          port: 16_379,
          db: 2,
          key_prefix: 'myapp:session:',
          ttl: ttl_seconds,
          expire_after: nil
        }
      }
    end

    it 'assigns the :ttl option to @default_options' do
      expect(default_options[:ttl]).to eq(ttl_seconds)
    end

    it 'does not assign :expire_after option to @default_options' do
      expect(default_options[:expire_after]).to be_nil
    end
  end

  describe 'when initializing with top-level redis options' do
    let :options do
      {
        key: random_string,
        secret: random_string,
        host: 'hostersons.local',
        port: 26_379,
        db: 4,
        key_prefix: 'appydoo:session:',
        expire_after: 60 * 60
      }
    end

    it 'creates a redis instance' do
      expect(store.instance_variable_get(:@redis)).not_to be_nil
    end

    it 'assigns the :host option to @default_options' do
      expect(default_options[:host]).to eq('hostersons.local')
    end

    it 'assigns the :port option to @default_options' do
      expect(default_options[:port]).to eq(26_379)
    end

    it 'assigns the :db option to @default_options' do
      expect(default_options[:db]).to eq(4)
    end

    it 'assigns the :key_prefix option to @default_options' do
      expect(default_options[:key_prefix]).to eq('appydoo:session:')
    end

    it 'assigns the :expire_after option to @default_options' do
      expect(default_options[:expire_after]).to eq(60 * 60)
    end
  end

  describe 'when initializing with existing redis object' do
    let :options do
      {
        key: random_string,
        secret: random_string,
        redis: {
          client: redis_client,
          key_prefix: 'myapp:session:',
          expire_after: 60 * 30
        }
      }
    end

    let(:redis_client) { double('redis_client') }

    it 'assigns given redis object to @redis' do
      expect(store.instance_variable_get(:@redis)).to be(redis_client)
    end

    it 'assigns the :client option to @default_options' do
      expect(default_options[:client]).to be(redis_client)
    end

    it 'assigns the :key_prefix option to @default_options' do
      expect(default_options[:key_prefix]).to eq('myapp:session:')
    end

    it 'assigns the :expire_after option to @default_options' do
      expect(default_options[:expire_after]).to eq(60 * 30)
    end
  end

  describe 'validating custom handlers' do
    %w(on_redis_down on_session_load_error).each do |h|
      context 'when nil' do
        it 'does not explode at init' do
          expect { store }.not_to raise_error
        end
      end

      context 'when callable' do
        let(:options) { { "#{h}": ->(*) { true } } }

        it 'does not explode at init' do
          expect { store }.not_to raise_error
        end
      end

      context 'when not callable' do
        let(:options) { { "#{h}": 'herpderp' } }

        it 'explodes at init' do
          expect { store }.to raise_error(ArgumentError)
        end
      end
    end
  end

  describe 'behavior' do
    let(:redis) { double('redis') }

    before { allow(store).to receive(:redis).with(anything).and_return(redis) }

    describe 'checking for session existence' do
      let(:session_id) { 'foo' }

      before do
        allow(store).to receive(:current_session_id)
          .with(:env).and_return(session_id)
      end

      context 'when session id is not provided' do
        context 'when session id is nil' do
          let(:session_id) { nil }

          it 'returns false' do
            expect(store.send(:session_exists?, :env)).to be(false)
          end
        end

        context 'when session id is empty string' do
          let(:session_id) { '' }

          it 'returns false' do
            allow(store).to receive(:current_session_id).with(:env).and_return('')
            expect(store.send(:session_exists?, :env)).to be(false)
          end
        end
      end

      context 'when session id is provided' do
        context 'when session id does not exist in redis' do
          it 'returns false' do
            allow(redis).to receive(:exists?).with('foo').and_return(false)
            expect(store.send(:session_exists?, :env)).to be(false)
          end
        end

        context 'when session id exists in redis' do
          it 'returns true' do
            allow(redis).to receive(:exists?).with('foo').and_return(true)
            expect(store.send(:session_exists?, :env)).to be(true)
          end
        end

        context 'when redis is down' do
          before do
            allow(redis).to receive(:exists?).and_raise(Redis::CannotConnectError)
          end

          it 'returns true (fallback to old behavior)' do
            expect(store.send(:session_exists?, :env)).to be(true)
          end

          it 'explodes when :on_redis_down re-raises' do
            store.on_redis_down = ->(e, *) { raise e }
            expect do
              store.send(:session_exists?, :env)
            end.to raise_error(Redis::CannotConnectError)
          end
        end
      end
    end

    describe 'fetching a session' do
      let :options do
        {
          key_prefix: 'customprefix::'
        }
      end

      let(:fake_key) { 'thisisarediskey' }

      describe 'generate_sid' do
        it 'generates a secure ID' do
          sid = store.send(:generate_sid, double('request'))
          expect(sid).to be_a(Rack::Session::SessionId)
        end
      end

      it 'retrieves the prefixed key from redis' do
        allow(store).to receive(:generate_sid).and_return(fake_key)
        expect(redis).to receive(:get).with("#{options[:key_prefix]}#{fake_key}")

        store.send(:find_session, double('env'), fake_key)
      end

      it 'generates new session when no sid' do
        allow(store).to receive(:generate_sid).and_return(fake_key)
        expect(store.send(:find_session, double('env'), nil)).to eq([fake_key, {}])
      end

      context 'when value missing in redis' do
        before do
          allow(redis).to receive(:get).with("#{options[:key_prefix]}#{fake_key}").and_return(nil)
        end

        it 'generates new sid' do
          new_sid = Rack::Session::SessionId.new('new-sid')
          allow(store).to receive(:generate_sid).and_return(new_sid)
          expect(store.send(:find_session, double('env'), fake_key)).to eq([new_sid, {}])
        end

        context 'when keep_sid is set' do
          let(:options) { super().merge(keep_sid: true) }

          it 'uses old sid with new session' do
            allow(redis).to receive(:get).with("#{options[:key_prefix]}#{fake_key}")
            allow(store).to receive(:generate_sid).and_raise('should not be called')
            expect(store.send(:find_session, double('env'), fake_key)).to eq([fake_key, {}])
          end
        end
      end

      context 'when redis is down' do
        before do
          allow(redis).to receive(:get).and_raise(Redis::CannotConnectError)
          allow(store).to receive(:generate_sid).and_return('foop')
        end

        it 'returns an empty session hash' do
          expect(store.send(:find_session, double('env'), fake_key).last)
            .to eq({})
        end

        it 'returns a newly generated sid' do
          expect(store.send(:find_session, double('env'), fake_key).first)
            .to eq('foop')
        end

        context 'when :on_redis_down re-raises' do
          before { store.on_redis_down = ->(e, *) { raise e } }

          it 'explodes' do
            expect do
              store.send(:find_session, double('env'), fake_key)
            end.to raise_error(Redis::CannotConnectError)
          end
        end
      end
    end

    describe 'destroying a session' do
      context 'when the key is in the cookie hash' do
        let(:request) { Rack::Request.new({ 'rack.request.cookie_hash' => cookie_hash }) }
        let(:cookie_hash) { double('cookie hash') }
        let(:fake_key) { 'thisisarediskey' }

        before do
          allow(cookie_hash).to receive(:[]).and_return(fake_key)
        end

        it 'deletes the prefixed key from redis' do
          expect(redis).to receive(:del)
            .with("#{options[:key_prefix]}#{fake_key}")

          store.send(:destroy, request)
        end

        context 'when no cookie hash in request' do
          let(:request) { Rack::Request.new({}) }

          it 'does nothing' do
            expect(redis).not_to receive(:del)
            store.send(:destroy, request)
          end
        end

        context 'when redis is down' do
          before do
            allow(redis).to receive(:del).and_raise(Redis::CannotConnectError)
          end

          it 'returns false' do
            expect(store.send(:destroy, request)).to be(false)
          end

          it 'explodes when :on_redis_down re-raises' do
            store.on_redis_down = ->(e, *) { raise e }
            expect do
              store.send(:destroy, request)
            end.to raise_error(Redis::CannotConnectError)
          end
        end
      end

      context 'when destroyed via #delete_session' do
        let(:redis) { double('redis', setnx: true) }

        it 'deletes the prefixed key from redis' do
          sid = store.send(:generate_sid, double('request'))
          expect(redis).to receive(:del).with("#{options[:key_prefix]}#{sid}")

          store.send(:delete_session, {}, sid, nil)
        end
      end
    end

    describe 'session encoding' do
      let(:env)          { double('env') }
      let(:session_id)   { 12_345 }
      let(:session_data) { { 'some' => 'data' } }
      let(:options)      { {} }
      let(:encoded_data) { Marshal.dump(session_data) }
      let(:redis)        { double('redis', set: nil, get: encoded_data) }
      let(:expected_encoding) { encoded_data }

      shared_examples_for 'serializer' do
        it 'encodes correctly' do
          expect(redis).to receive(:set).with('12345', expected_encoding)
          store.send(:write_session, env, session_id, session_data, options)
        end

        it 'decodes correctly' do
          expect(store.send(:find_session, env, session_id))
            .to eq([session_id, session_data])
        end
      end

      describe 'marshal' do
        let(:options) { { serializer: :marshal } }

        it_behaves_like 'serializer'
      end

      describe 'json' do
        let(:options) { { serializer: :json } }
        let(:encoded_data) { '{"some":"data"}' }

        it_behaves_like 'serializer'
      end

      describe 'hybrid' do
        let(:options) { { serializer: :hybrid } }
        let(:expected_encoding) { '{"some":"data"}' }

        context 'with marshal encoded data' do
          it_behaves_like 'serializer'
        end

        context 'with json encoded data' do
          let(:encoded_data) { '{"some":"data"}' }

          it_behaves_like 'serializer'
        end
      end

      describe 'custom' do
        let :custom_serializer do
          Class.new do
            def self.load(_value)
              { 'some' => 'data' }
            end

            def self.dump(_value)
              'somedata'
            end
          end
        end

        let(:options) { { serializer: custom_serializer } }
        let(:expected_encoding) { 'somedata' }

        it_behaves_like 'serializer'
      end
    end

    describe 'handling decode errors' do
      subject(:load_session_from_redis) do
        ->(sid) { store.send(:load_session_from_redis, request, sid) }
      end

      let(:request) { double('request') }

      context 'when a class is serialized that does not exist' do
        let(:redis) do
          double('redis',
                 get: "\x04\bo:\nNonExistentClass\x00",
                 del: true)
        end

        it 'returns an empty session' do
          expect(load_session_from_redis['whatever']).to be_nil
        end

        it 'destroys and drops the session' do
          expect(store).to receive(:destroy_session_from_sid)
            .with('wut', drop: true, request: request)
          load_session_from_redis['wut']
        end

        context 'when a custom on_session_load_error handler is provided' do
          let(:handler) { double('handler') }
          let(:sid) { 'foo' }

          before { store.on_session_load_error = handler }

          it 'passes the error and the sid to the handler' do
            expect(handler).to receive(:call).with(be_a(StandardError), sid)
            load_session_from_redis[sid]
          end
        end
      end

      context 'when the encoded data is invalid' do
        let(:redis) { double('redis', get: "\x00\x00\x00\x00", del: true) }

        it 'returns an empty session' do
          expect(load_session_from_redis['bar']).to be_nil
        end

        it 'destroys and drops the session' do
          expect(store).to receive(:destroy_session_from_sid)
            .with('wut', drop: true, request: request)
          load_session_from_redis['wut']
        end

        context 'when a custom on_session_load_error handler is provided' do
          let(:handler) { double('handler') }
          let(:sid) { 'foo' }

          before { store.on_session_load_error = handler }

          it 'passes the error and the sid to the handler' do
            expect(handler).to receive(:call).with(be_a(StandardError), sid)
            load_session_from_redis[sid]
          end
        end
      end
    end

    describe 'setting the session' do
      subject(:write_session) { ->(data:) { store.send(:write_session, request, sid, data) } }

      let(:sid) { 1234 }
      let(:request) { Rack::Request.new({ 'rack.session.options' => {} }) }
      let(:redis) { Redis.new }

      it 'allows changing the session' do
        write_session[data: { 'foo' => 'bar' }]
        data2 = { 'baz' => 'wat' }
        write_session[data: data2]
        _, session = store.send(:find_session, request, sid)
        expect(session).to eq(data2)
      end

      context 'when the session has an expiry' do
        let(:request) { Rack::Request.new({ 'rack.session.options' => { expire_after: 60 } }) }

        it 'allows changing the session' do
          write_session[data: { 'foo' => 'bar' }]
          data2 = { 'baz' => 'wat' }
          write_session[data: data2]
          _, session = store.send(:find_session, request, sid)
          expect(session).to eq(data2)
        end
      end

      context 'when redis is down' do
        let(:redis) { double('redis') }
        let(:redis_exception_type) { Redis::CannotConnectError }

        before { allow(redis).to receive(:set).and_raise(redis_exception_type) }

        it 'returns false' do
          expect(write_session[data: { 'foo' => 'bar' }]).to be false
        end

        it 'calls on_redis_down' do
          store.on_redis_down = double('on_redis_down')
          expect(store.on_redis_down).to receive(:call).with(
            be_a(redis_exception_type), request, sid
          )
          write_session[data: { 'foo' => 'bar' }]
        end

        context 'when :on_redis_down re-raises' do
          before { store.on_redis_down = ->(e, *) { raise e } }

          it 'explodes' do
            expect do
              write_session[data: { 'foo' => 'bar' }]
            end.to raise_error(Redis::CannotConnectError)
          end
        end
      end
    end
  end
end
