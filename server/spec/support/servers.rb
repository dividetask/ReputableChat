# frozen_string_literal: true

require "rack/mock"
require "tmpdir"
require "agnostic/server"

# Whole servers in one process, each with its own data directory, talking to
# each other through their Rack apps rather than the network.
module Servers
  Network = Struct.new(:apps) do
    def call(method, address, body, headers = {})
      uri = URI(address)
      app = apps.fetch("#{uri.scheme}://#{uri.host}")
      env = { method: method.to_s.upcase }
      headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
      if body
        env[:input] = body.is_a?(String) ? body : JSON.generate(body)
        env["CONTENT_TYPE"] = "application/json"
      end
      response = Rack::MockRequest.new(app).request(method.to_s.upcase, uri.request_uri, env)
      unless response.status.between?(200, 299)
        parsed = (JSON.parse(response.body) rescue nil)
        raise Agnostic::Peers::HttpError.new("#{address} answered #{response.status}", status: response.status,
                                                                                         retry_after: response.headers["retry-after"],
                                                                                         body: parsed)
      end

      JSON.parse(response.body)
    end
  end

  def network = @network ||= Network.new({})

  # The Rack env headers of an upload signed by a host account.
  def upload_env(signer, path, body, ts: Time.now.to_i)
    Agnostic::UploadAuth.headers(signer, :post, path, body, ts)
                        .to_h { |name, value| ["HTTP_#{name.upcase.tr('-', '_')}", value] }
                        .merge("CONTENT_TYPE" => "application/json")
  end

  # A signed upload straight to a server's app.
  def signed_post(server, path, body, signer:, ts: Time.now.to_i)
    json = body.is_a?(String) ? body : JSON.generate(body)
    Rack::MockRequest.new(server.app).post(path, upload_env(signer, path, json, ts: ts).merge(input: json))
  end

  # A server at http://<name>, peering with the others named.
  # Live at once unless told otherwise, as a server with nothing to catch up
  # with would be.
  def boot(name, peers: [], clock: -> { Time.now.to_i }, host: {}, live: true)
    dir = Dir.mktmpdir("agnostic-#{name}")
    (@dirs ||= []) << dir
    settings = Agnostic::Settings.new(
      { "data_dir" => dir, "host" => { "handle" => name }.merge(host),
        "peers" => { "urls" => peers.map { |p| "http://#{p}" } } }, env: { "RACK_ENV" => "development" }
    )
    server = Agnostic::Server.new(settings: settings, clock: clock, http: network)
    server.go_live if live
    network.apps["http://#{name}"] = server.app
    server
  end

  def teardown = Array(@dirs).each { |d| FileUtils.rm_rf(d) }
end
