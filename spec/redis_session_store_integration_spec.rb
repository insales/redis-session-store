require 'logger'

Bundler.require

describe RedisSessionStore do
  subject(:store) { described_class.new(dummy_app, options) }

  let(:rack_response) { [200, { 'Content-Type' => 'text/html' }, 'Hello, session'] }
  let(:options) { { key: 'sess', keep_sid: true, skip_exists: true } }
  let(:response) do
    Rack::MockRequest.new(ActionDispatch::Cookies.new(store)).get('/')
  end
  let(:dummy_app) do
    lambda do |env|
      payload.call(env, env[Rack::RACK_SESSION])
      rack_response
    end
  end
  let(:payload) do
    lambda do |_env, session|
      expect(session.id).to be_nil
      session.options[:renew] = true
    end
  end

  it 'works when renew without existing sid' do
    expect(response).to be_successful
  end
end
